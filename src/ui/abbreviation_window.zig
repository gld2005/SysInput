const std = @import("std");
const sysinput = @import("root").sysinput;
const api = sysinput.win32.api;
const abbreviation = sysinput.text.abbreviation;

const CLASS = "SysInputAbbreviationWindow";
const ID_SEARCH = 3100;
const ID_LIST = 3101;
const ID_TRIGGER = 3102;
const ID_EXPANSION = 3103;
const ID_ENABLED = 3104;
const ID_CASE = 3105;
const ID_SAVE = 3106;
const ID_DELETE = 3107;
const ID_IMPORT = 3108;
const ID_EXPORT = 3109;
const ID_STATS = 3110;
const WM_FILE_JOB_DONE = api.WM_APP + 20;

var instance: api.HINSTANCE = undefined;
var store: *abbreviation.Store = undefined;
var window: ?api.HWND = null;
var class_atom: api.ATOM = 0;
var list: ?api.HWND = null;
var search: ?api.HWND = null;
var trigger: ?api.HWND = null;
var expansion: ?api.HWND = null;
var enabled: ?api.HWND = null;
var case_sensitive: ?api.HWND = null;
var visible_indices: [abbreviation.MAX_ENTRIES]u16 = undefined;
var visible_count: usize = 0;
var file_job: ?std.Thread = null;
var file_job_running = std.atomic.Value(bool).init(false);

const FileJob = struct { save: bool, path: [260:0]u8 };

pub fn init(module: api.HINSTANCE, abbreviation_store: *abbreviation.Store) !void {
    instance = module;
    store = abbreviation_store;
    const icon = api.LoadIconA(instance, api.makeIntResource(101));
    const wc = api.WNDCLASSEX{
        .cbSize = @sizeOf(api.WNDCLASSEX),
        .style = 0,
        .lpfnWndProc = proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = icon,
        .hCursor = api.LoadCursorA(null, api.makeIntResource(api.IDC_ARROW)),
        .hbrBackground = @ptrCast(api.GetStockObject(api.WHITE_BRUSH).?),
        .lpszMenuName = null,
        .lpszClassName = CLASS,
        .hIconSm = icon,
    };
    class_atom = api.RegisterClassExA(&wc);
    if (class_atom == 0) return error.AbbreviationWindowRegistrationFailed;
}

pub fn deinit() void {
    if (file_job) |thread| thread.join();
    file_job = null;
    if (window) |handle| _ = api.DestroyWindow(handle);
    window = null;
    if (class_atom != 0) _ = api.UnregisterClassA(CLASS, instance);
    class_atom = 0;
}

pub fn show() void {
    if (window == null) create() catch return;
    refresh();
    _ = api.ShowWindow(window.?, api.SW_SHOW);
    _ = api.SetForegroundWindow(window.?);
}

fn control(class: [*:0]const u8, title: [*:0]const u8, style: api.DWORD, x: c_int, y: c_int, width: c_int, height: c_int, parent: api.HWND, id: usize) !api.HWND {
    const edge: api.DWORD = if (std.mem.eql(u8, std.mem.span(class), "EDIT") or std.mem.eql(u8, std.mem.span(class), "LISTBOX")) api.WS_EX_CLIENTEDGE else 0;
    return api.CreateWindowExA(edge, class, title, api.WS_CHILD | api.WS_VISIBLE | style, x, y, width, height, parent, if (id == 0) null else @ptrFromInt(id), instance, null) orelse error.AbbreviationControlCreationFailed;
}

fn create() !void {
    window = api.CreateWindowExA(api.WS_EX_APPWINDOW, CLASS, "SysInput Abbreviations", api.WS_OVERLAPPEDWINDOW, api.CW_USEDEFAULT, api.CW_USEDEFAULT, 820, 610, null, null, instance, null) orelse return error.AbbreviationWindowCreationFailed;
    const parent = window.?;
    _ = try control("STATIC", "Search", 0, 18, 18, 60, 22, parent, 0);
    search = try control("EDIT", "", api.ES_AUTOHSCROLL | api.WS_TABSTOP, 82, 16, 700, 26, parent, ID_SEARCH);
    list = try control("LISTBOX", "", api.WS_VSCROLL | api.LBS_NOTIFY | api.WS_TABSTOP, 18, 54, 764, 250, parent, ID_LIST);
    _ = try control("STATIC", "Trigger", 0, 18, 320, 70, 22, parent, 0);
    trigger = try control("EDIT", "", api.ES_AUTOHSCROLL | api.WS_TABSTOP, 92, 316, 220, 28, parent, ID_TRIGGER);
    _ = try control("STATIC", "Expansion", 0, 326, 320, 78, 22, parent, 0);
    expansion = try control("EDIT", "", api.ES_MULTILINE | api.ES_AUTOVSCROLL | api.WS_VSCROLL | api.WS_TABSTOP, 408, 316, 374, 90, parent, ID_EXPANSION);
    enabled = try control("BUTTON", "Enabled", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 18, 360, 130, 26, parent, ID_ENABLED);
    case_sensitive = try control("BUTTON", "Case sensitive", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 160, 360, 150, 26, parent, ID_CASE);
    _ = api.SendMessageA(enabled.?, api.BM_SETCHECK, api.BST_CHECKED, 0);
    _ = try control("BUTTON", "Add / update", api.BS_PUSHBUTTON | api.WS_TABSTOP, 18, 420, 130, 30, parent, ID_SAVE);
    _ = try control("BUTTON", "Delete", api.BS_PUSHBUTTON | api.WS_TABSTOP, 160, 420, 100, 30, parent, ID_DELETE);
    _ = try control("BUTTON", "Import TSV...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 18, 472, 120, 30, parent, ID_IMPORT);
    _ = try control("BUTTON", "Export TSV...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 150, 472, 120, 30, parent, ID_EXPORT);
    _ = try control("BUTTON", "Clear usage statistics", api.BS_PUSHBUTTON | api.WS_TABSTOP, 282, 472, 170, 30, parent, ID_STATS);
    _ = try control("STATIC", "Tab expands fully; Ctrl+Right accepts one word.", 0, 18, 526, 700, 22, parent, 0);
}

fn getText(handle: ?api.HWND, buffer: [:0]u8) []const u8 {
    const target = handle orelse return "";
    const len = api.GetWindowTextA(target, buffer.ptr, @intCast(buffer.len));
    return if (len > 0) buffer[0..@intCast(len)] else "";
}

fn refresh() void {
    const handle = list orelse return;
    _ = api.SendMessageA(handle, api.LB_RESETCONTENT, 0, 0);
    visible_count = 0;
    var filter_buffer: [64:0]u8 = [_:0]u8{0} ** 64;
    const filter = getText(search, &filter_buffer);
    var entries: [abbreviation.MAX_ENTRIES]abbreviation.Entry = undefined;
    const count = store.copyEntries(&entries);
    for (entries[0..count], 0..) |*entry, index| {
        if (filter.len > 0 and std.ascii.indexOfIgnoreCase(entry.triggerSlice(), filter) == null and std.ascii.indexOfIgnoreCase(entry.expansionSlice(), filter) == null) continue;
        visible_indices[visible_count] = @intCast(index);
        visible_count += 1;
        var row: [320:0]u8 = undefined;
        const rendered = std.fmt.bufPrint(row[0..319], "[{s}] {s} -> {s}", .{ if (entry.enabled) "x" else " ", entry.triggerSlice(), entry.expansionSlice() }) catch continue;
        row[rendered.len] = 0;
        _ = api.SendMessageA(handle, api.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&row)));
    }
}

fn selected() ?usize {
    const handle = list orelse return null;
    const value = api.SendMessageA(handle, api.LB_GETCURSEL, 0, 0);
    if (value == api.LB_ERR or value < 0 or value >= visible_count) return null;
    return visible_indices[@intCast(value)];
}

fn loadSelected() void {
    const index = selected() orelse return;
    var entries: [abbreviation.MAX_ENTRIES]abbreviation.Entry = undefined;
    const count = store.copyEntries(&entries);
    if (index >= count) return;
    const entry = &entries[index];
    var key: [abbreviation.MAX_TRIGGER_BYTES + 1:0]u8 = [_:0]u8{0} ** (abbreviation.MAX_TRIGGER_BYTES + 1);
    var value: [abbreviation.MAX_EXPANSION_BYTES + 1:0]u8 = [_:0]u8{0} ** (abbreviation.MAX_EXPANSION_BYTES + 1);
    @memcpy(key[0..entry.trigger_len], entry.triggerSlice());
    @memcpy(value[0..entry.expansion_len], entry.expansionSlice());
    _ = api.SetWindowTextA(trigger.?, &key);
    _ = api.SetWindowTextA(expansion.?, &value);
    _ = api.SendMessageA(enabled.?, api.BM_SETCHECK, if (entry.enabled) api.BST_CHECKED else api.BST_UNCHECKED, 0);
    _ = api.SendMessageA(case_sensitive.?, api.BM_SETCHECK, if (entry.case_sensitive) api.BST_CHECKED else api.BST_UNCHECKED, 0);
}

fn saveEntry() void {
    var key_buffer: [abbreviation.MAX_TRIGGER_BYTES + 1:0]u8 = [_:0]u8{0} ** (abbreviation.MAX_TRIGGER_BYTES + 1);
    var value_buffer: [abbreviation.MAX_EXPANSION_BYTES + 1:0]u8 = [_:0]u8{0} ** (abbreviation.MAX_EXPANSION_BYTES + 1);
    const key = getText(trigger, &key_buffer);
    const value = getText(expansion, &value_buffer);
    if (store.lookup(key) != null and api.MessageBoxA(window, "This trigger exists. Replace it?", "SysInput", api.MB_YESNO | api.MB_ICONWARNING) != api.IDYES) return;
    _ = store.upsert(key, value, api.SendMessageA(enabled.?, api.BM_GETCHECK, 0, 0) == api.BST_CHECKED, api.SendMessageA(case_sensitive.?, api.BM_GETCHECK, 0, 0) == api.BST_CHECKED) catch {
        _ = api.MessageBoxA(window, "Trigger or expansion is invalid.", "SysInput", api.MB_OK | api.MB_ICONWARNING);
        return;
    };
    refresh();
}

fn chooseFile(save: bool) ?[260:0]u8 {
    var path: [260:0]u8 = [_:0]u8{0} ** 260;
    var dialog = std.mem.zeroes(api.OPENFILENAMEA);
    dialog.lStructSize = @sizeOf(api.OPENFILENAMEA);
    dialog.hwndOwner = window;
    dialog.lpstrFilter = "TSV files (*.tsv)\x00*.tsv\x00All files (*.*)\x00*.*\x00\x00";
    dialog.lpstrFile = &path;
    dialog.nMaxFile = path.len;
    dialog.Flags = api.OFN_PATHMUSTEXIST | api.OFN_NOCHANGEDIR | (if (save) @as(api.DWORD, 0) else api.OFN_FILEMUSTEXIST);
    dialog.lpstrDefExt = "tsv";
    if ((if (save) api.GetSaveFileNameA(&dialog) else api.GetOpenFileNameA(&dialog)) == 0) return null;
    return path;
}

fn startFileJob(save: bool, path: [260:0]u8) void {
    if (file_job_running.load(.acquire)) {
        _ = api.MessageBoxA(window, "An import or export is already running.", "SysInput", api.MB_OK);
        return;
    }
    if (file_job) |thread| {
        thread.join();
        file_job = null;
    }
    const job = std.heap.page_allocator.create(FileJob) catch return;
    job.* = .{ .save = save, .path = path };
    file_job_running.store(true, .release);
    file_job = std.Thread.spawn(.{}, runFileJob, .{job}) catch {
        file_job_running.store(false, .release);
        std.heap.page_allocator.destroy(job);
        return;
    };
}

fn runFileJob(job: *FileJob) void {
    defer std.heap.page_allocator.destroy(job);
    const path = std.mem.sliceTo(&job.path, 0);
    if (job.save) store.exportTsv(path) catch {} else _ = store.importTsv(path) catch 0;
    file_job_running.store(false, .release);
    if (window) |handle| _ = api.PostMessageA(handle, WM_FILE_JOB_DONE, 0, 0);
}

fn proc(hwnd: api.HWND, message: api.UINT, w: api.WPARAM, l: api.LPARAM) callconv(.C) api.LRESULT {
    switch (message) {
        api.WM_COMMAND => {
            const id = w & 0xffff;
            const notification = (w >> 16) & 0xffff;
            if (id == ID_SEARCH and notification == api.EN_CHANGE) refresh() else if (id == ID_LIST and notification == 1) loadSelected() else if (notification == api.BN_CLICKED) switch (id) {
                ID_SAVE => saveEntry(),
                ID_DELETE => if (selected()) |index| {
                    store.remove(index) catch {};
                    refresh();
                },
                ID_STATS => {
                    store.clearStatistics();
                    refresh();
                },
                ID_IMPORT => if (api.MessageBoxA(window, "Importing will replace duplicate triggers. Continue?", "SysInput", api.MB_YESNO | api.MB_ICONWARNING) == api.IDYES) {
                    if (chooseFile(false)) |path| startFileJob(false, path);
                },
                ID_EXPORT => if (chooseFile(true)) |path| startFileJob(true, path),
                else => {},
            };
            return 0;
        },
        WM_FILE_JOB_DONE => {
            if (file_job) |thread| thread.join();
            file_job = null;
            refresh();
            return 0;
        },
        api.WM_CLOSE => {
            _ = api.ShowWindow(hwnd, api.SW_HIDE);
            return 0;
        },
        api.WM_DESTROY => {
            window = null;
            list = null;
            search = null;
            trigger = null;
            expansion = null;
            enabled = null;
            case_sensitive = null;
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, message, w, l),
    }
}
