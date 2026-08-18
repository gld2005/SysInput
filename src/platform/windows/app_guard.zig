const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const exclusions = sysinput.core.application_exclusions;

pub const Decision = enum { allowed, excluded, protected };
pub const ResolvedApplication = struct {
    decision: Decision,
    path: [exclusions.MAX_PATH_BYTES]u8 = undefined,
    path_len: u16 = 0,

    pub fn pathSlice(self: *const ResolvedApplication) []const u8 {
        return self.path[0..self.path_len];
    }
};

const CACHE_SIZE: usize = 64;
const CacheEntry = struct {
    pid: api.DWORD = 0,
    generation: u64 = 0,
    decision: Decision = .protected,
    path: [exclusions.MAX_PATH_BYTES]u8 = undefined,
    path_len: u16 = 0,
    stamp: u64 = 0,
};

var exclusion_store: *exclusions.Store = undefined;
var cache: [CACHE_SIZE]CacheEntry = [_]CacheEntry{.{}} ** CACHE_SIZE;
var cache_clock: u64 = 1;
var self_integrity: u32 = 0;
var initialized = false;
var cache_mutex = std.Thread.Mutex{};
threadlocal var uia_initialized = false;
threadlocal var uia_automation: ?*IUIAutomation = null;

const CLSID_CUIAutomation = api.GUID{
    .Data1 = 0xff48dba4,
    .Data2 = 0x60ef,
    .Data3 = 0x4201,
    .Data4 = .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e },
};
const IID_IUIAutomation = api.GUID{
    .Data1 = 0x30cbe57d,
    .Data2 = 0xd9d0,
    .Data3 = 0x452a,
    .Data4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee },
};
const UIA_IsPasswordPropertyId: i32 = 30019;

const IUIAutomation = extern struct { lpVtbl: *const IUIAutomationVtbl };
const IUIAutomationElement = extern struct { lpVtbl: *const IUIAutomationElementVtbl };
const IUIAutomationVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*IUIAutomation) callconv(.winapi) u32,
    CompareElements: *const anyopaque,
    CompareRuntimeIds: *const anyopaque,
    GetRootElement: *const anyopaque,
    ElementFromHandle: *const anyopaque,
    ElementFromPoint: *const anyopaque,
    GetFocusedElement: *const fn (*IUIAutomation, **IUIAutomationElement) callconv(.winapi) api.HRESULT,
};
const IUIAutomationElementVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*IUIAutomationElement) callconv(.winapi) u32,
    SetFocus: *const anyopaque,
    GetRuntimeId: *const anyopaque,
    FindFirst: *const anyopaque,
    FindAll: *const anyopaque,
    FindFirstBuildCache: *const anyopaque,
    FindAllBuildCache: *const anyopaque,
    BuildUpdatedCache: *const anyopaque,
    GetCurrentPropertyValue: *const fn (*IUIAutomationElement, i32, *anyopaque) callconv(.winapi) api.HRESULT,
};

pub fn init(store: *exclusions.Store) void {
    exclusion_store = store;
    self_integrity = processIntegrity(api.GetCurrentProcess()) orelse 0;
    invalidateCache();
    initialized = true;
}

pub fn deinit() void {
    initialized = false;
}

pub fn invalidateCache() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    invalidateCacheLocked();
}

fn invalidateCacheLocked() void {
    cache = [_]CacheEntry{.{}} ** CACHE_SIZE;
    cache_clock = 1;
}

pub fn evaluate(window: ?api.HWND) ResolvedApplication {
    if (!initialized) return .{ .decision = .protected };
    const foreground = window orelse return .{ .decision = .protected };
    if (api.GetForegroundWindow() != foreground) return .{ .decision = .protected };
    if (isStandardPasswordControl() or uiaIsPassword()) return .{ .decision = .protected };

    var pid: api.DWORD = 0;
    if (api.GetWindowThreadProcessId(foreground, &pid) == 0 or pid == 0 or pid == api.GetCurrentProcessId()) {
        return .{ .decision = .protected };
    }
    cache_mutex.lock();
    defer cache_mutex.unlock();
    const generation = exclusion_store.currentGeneration();
    for (&cache) |*entry| {
        if (entry.pid != pid or entry.generation != generation) continue;
        entry.stamp = tick();
        return copyResult(entry);
    }

    const process = api.OpenProcess(api.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse
        return .{ .decision = .protected };
    defer _ = api.CloseHandle(process);
    if (self_integrity != 0) {
        const target_integrity = processIntegrity(process) orelse return .{ .decision = .protected };
        if (target_integrity > self_integrity) return .{ .decision = .protected };
    }

    var raw_path: [exclusions.MAX_PATH_BYTES]u8 = undefined;
    var raw_len: api.DWORD = raw_path.len;
    if (api.QueryFullProcessImageNameA(process, 0, &raw_path, &raw_len) == 0 or raw_len == 0) {
        return .{ .decision = .protected };
    }
    var normalized_storage: [exclusions.MAX_PATH_BYTES]u8 = undefined;
    const normalized = exclusions.normalizePath(raw_path[0..raw_len], &normalized_storage) orelse
        return .{ .decision = .protected };
    const decision: Decision = if (isSecurityProcess(normalized))
        .protected
    else if (exclusion_store.contains(normalized))
        .excluded
    else
        .allowed;
    var selected = weakestCacheEntry();
    selected.pid = pid;
    selected.generation = generation;
    selected.decision = decision;
    selected.path_len = @intCast(normalized.len);
    @memcpy(selected.path[0..normalized.len], normalized);
    selected.stamp = tick();
    return copyResult(selected);
}

pub fn addWindow(window: ?api.HWND) !bool {
    const result = resolvePathOnly(window);
    if (result.path_len == 0) return error.ApplicationPathUnavailable;
    const added = try exclusion_store.add(result.pathSlice());
    invalidateCache();
    return added;
}

fn resolvePathOnly(window: ?api.HWND) ResolvedApplication {
    const target = window orelse return .{ .decision = .protected };
    var pid: api.DWORD = 0;
    if (api.GetWindowThreadProcessId(target, &pid) == 0 or pid == 0 or pid == api.GetCurrentProcessId()) {
        return .{ .decision = .protected };
    }
    const process = api.OpenProcess(api.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse
        return .{ .decision = .protected };
    defer _ = api.CloseHandle(process);
    if (self_integrity != 0) {
        const target_integrity = processIntegrity(process) orelse return .{ .decision = .protected };
        if (target_integrity > self_integrity) return .{ .decision = .protected };
    }
    var raw_path: [exclusions.MAX_PATH_BYTES]u8 = undefined;
    var raw_len: api.DWORD = raw_path.len;
    if (api.QueryFullProcessImageNameA(process, 0, &raw_path, &raw_len) == 0 or raw_len == 0) {
        return .{ .decision = .protected };
    }
    var normalized_storage: [exclusions.MAX_PATH_BYTES]u8 = undefined;
    const normalized = exclusions.normalizePath(raw_path[0..raw_len], &normalized_storage) orelse
        return .{ .decision = .protected };
    if (isSecurityProcess(normalized)) return .{ .decision = .protected };
    var result = ResolvedApplication{ .decision = .allowed, .path_len = @intCast(normalized.len) };
    @memcpy(result.path[0..normalized.len], normalized);
    return result;
}

fn isStandardPasswordControl() bool {
    const focused = api.getFocusedWindow() orelse return true;
    const style = api.GetWindowLongPtrA(focused, api.GWL_STYLE);
    return (@as(usize, @bitCast(style)) & api.ES_PASSWORD) != 0;
}

fn uiaIsPassword() bool {
    const automation = getUiaAutomation() orelse return false;
    var element: *IUIAutomationElement = undefined;
    if (automation.lpVtbl.GetFocusedElement(automation, &element) < 0) return false;
    defer _ = element.lpVtbl.Release(element);
    var variant: [24]u8 align(8) = [_]u8{0} ** 24;
    if (element.lpVtbl.GetCurrentPropertyValue(element, UIA_IsPasswordPropertyId, &variant) < 0) return false;
    defer _ = api.VariantClear(&variant);
    const variant_type = std.mem.readInt(u16, variant[0..2], .little);
    if (variant_type != api.VT_BOOL) return false;
    return std.mem.readInt(i16, variant[8..10], .little) != 0;
}

fn getUiaAutomation() ?*IUIAutomation {
    if (uia_initialized) return uia_automation;
    uia_initialized = true;
    _ = api.CoInitializeEx(null, api.COINIT_MULTITHREADED);
    var object: *anyopaque = undefined;
    if (api.CoCreateInstance(&CLSID_CUIAutomation, null, api.CLSCTX_INPROC_SERVER, &IID_IUIAutomation, &object) < 0) return null;
    uia_automation = @ptrCast(@alignCast(object));
    return uia_automation;
}

fn isSecurityProcess(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.ascii.eqlIgnoreCase(base, "logonui.exe") or
        std.ascii.eqlIgnoreCase(base, "credentialuibroker.exe") or
        std.ascii.eqlIgnoreCase(base, "consent.exe");
}

fn processIntegrity(process: api.HANDLE) ?u32 {
    var token: api.HANDLE = undefined;
    if (api.OpenProcessToken(process, api.TOKEN_QUERY, &token) == 0) return null;
    defer _ = api.CloseHandle(token);
    var storage: [256]u8 align(@alignOf(api.TOKEN_MANDATORY_LABEL)) = undefined;
    var returned: api.DWORD = 0;
    if (api.GetTokenInformation(token, api.TokenIntegrityLevel, &storage, storage.len, &returned) == 0) return null;
    const label: *const api.TOKEN_MANDATORY_LABEL = @ptrCast(&storage);
    const count = api.GetSidSubAuthorityCount(label.Label.Sid) orelse return null;
    if (count.* == 0) return null;
    const rid = api.GetSidSubAuthority(label.Label.Sid, count.* - 1) orelse return null;
    return rid.*;
}

fn weakestCacheEntry() *CacheEntry {
    var index: usize = 0;
    for (cache, 0..) |entry, candidate| {
        if (entry.pid == 0) return &cache[candidate];
        if (entry.stamp < cache[index].stamp) index = candidate;
    }
    return &cache[index];
}

fn copyResult(entry: *const CacheEntry) ResolvedApplication {
    var result = ResolvedApplication{ .decision = entry.decision, .path_len = entry.path_len };
    @memcpy(result.path[0..entry.path_len], entry.path[0..entry.path_len]);
    return result;
}

fn tick() u64 {
    cache_clock +%= 1;
    if (cache_clock == 0) cache_clock = 1;
    return cache_clock;
}
