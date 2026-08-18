const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;

const WINDOW_CLASS = "SysInputLifecycleWindow";
const WINDOW_TITLE = "SysInput";
const MUTEX_NAME = "Local\\SysInput.v0.2.SingleInstance";
const RUN_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const SETTINGS_KEY = "Software\\SysInput";
const RUN_VALUE = "SysInput";
const CONFIGURED_VALUE = "StartupConfigured";

const TRAY_CALLBACK = api.WM_APP + 2;
const TRAY_ID = 1;
const MENU_TOGGLE = 1001;
const MENU_STARTUP = 1002;
const MENU_EXIT = 1003;

pub const Options = struct {
    background: bool = false,
    startup_write: bool = true,

    pub fn parse(args: []const []const u8) Options {
        var result = Options{};
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--background")) result.background = true;
            if (std.mem.eql(u8, arg, "--no-startup-write")) result.startup_write = false;
        }
        return result;
    }
};

pub const SingleInstance = struct {
    handle: api.HANDLE,

    pub fn acquire() !?SingleInstance {
        return acquireNamed(MUTEX_NAME);
    }

    pub fn acquireNamed(name: [*:0]const u8) !?SingleInstance {
        const handle = api.CreateMutexA(null, 0, name) orelse return error.MutexCreationFailed;
        if (api.GetLastError() == api.ERROR_ALREADY_EXISTS) {
            _ = api.CloseHandle(handle);
            return null;
        }
        return .{ .handle = handle };
    }

    pub fn deinit(self: *SingleInstance) void {
        _ = api.CloseHandle(self.handle);
    }
};

pub const Callbacks = struct {
    set_enabled: *const fn (bool) bool,
};

var g_allocator: std.mem.Allocator = undefined;
var g_instance: ?api.HINSTANCE = null;
var g_window: ?api.HWND = null;
var g_window_class: api.ATOM = 0;
var g_icon_data: api.NOTIFYICONDATAA = undefined;
var g_icon_added = false;
var g_enabled = true;
var g_callbacks: Callbacks = undefined;

pub fn init(
    allocator: std.mem.Allocator,
    instance: api.HINSTANCE,
    options: Options,
    callbacks: Callbacks,
) !void {
    if (g_window != null) return;
    g_allocator = allocator;
    g_instance = instance;
    g_callbacks = callbacks;
    g_enabled = true;

    const wc = api.WNDCLASSEX{
        .cbSize = @sizeOf(api.WNDCLASSEX),
        .style = 0,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = @ptrCast(api.GetStockObject(api.WHITE_BRUSH).?),
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS,
        .hIconSm = null,
    };
    g_window_class = api.RegisterClassExA(&wc);
    if (g_window_class == 0) return error.WindowClassRegistrationFailed;
    errdefer {
        _ = api.UnregisterClassA(WINDOW_CLASS, instance);
        g_window_class = 0;
    }

    g_window = api.CreateWindowExA(
        0,
        WINDOW_CLASS,
        WINDOW_TITLE,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        instance,
        null,
    ) orelse return error.WindowCreationFailed;
    errdefer {
        _ = api.DestroyWindow(g_window.?);
        g_window = null;
    }

    try addTrayIcon();
    if (options.startup_write) initializeStartupPreference() catch {};
    _ = options.background;
}

pub fn deinit() void {
    if (g_icon_added) {
        _ = api.Shell_NotifyIconA(api.NIM_DELETE, &g_icon_data);
        g_icon_added = false;
    }
    if (g_window) |window| {
        _ = api.DestroyWindow(window);
        g_window = null;
    }
    if (g_window_class != 0 and g_instance != null) {
        _ = api.UnregisterClassA(WINDOW_CLASS, g_instance.?);
        g_window_class = 0;
    }
}

pub fn startupCommand(allocator: std.mem.Allocator, executable_path: []const u8) ![:0]u8 {
    return std.fmt.allocPrintZ(allocator, "\"{s}\" --background", .{executable_path});
}

pub fn isStartupEnabled() bool {
    var key: api.HKEY = undefined;
    if (api.RegOpenKeyExA(api.HKEY_CURRENT_USER, RUN_KEY, 0, api.KEY_QUERY_VALUE, &key) != api.ERROR_SUCCESS) {
        return false;
    }
    defer _ = api.RegCloseKey(key);
    return api.RegQueryValueExA(key, RUN_VALUE, null, null, null, null) == api.ERROR_SUCCESS;
}

pub fn setStartupEnabled(allocator: std.mem.Allocator, enabled: bool) !void {
    var key: api.HKEY = undefined;
    if (api.RegCreateKeyExA(
        api.HKEY_CURRENT_USER,
        RUN_KEY,
        0,
        null,
        0,
        api.KEY_SET_VALUE,
        null,
        &key,
        null,
    ) != api.ERROR_SUCCESS) return error.RegistryOpenFailed;
    defer _ = api.RegCloseKey(key);

    if (!enabled) {
        const status = api.RegDeleteValueA(key, RUN_VALUE);
        if (status != api.ERROR_SUCCESS and status != api.ERROR_FILE_NOT_FOUND) return error.RegistryWriteFailed;
        try markStartupConfigured();
        return;
    }

    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    const command = try startupCommand(allocator, executable);
    defer allocator.free(command);
    if (api.RegSetValueExA(
        key,
        RUN_VALUE,
        0,
        api.REG_SZ,
        command.ptr,
        @intCast(command.len + 1),
    ) != api.ERROR_SUCCESS) return error.RegistryWriteFailed;
    try markStartupConfigured();
}

fn initializeStartupPreference() !void {
    if (!startupWasConfigured()) {
        try setStartupEnabled(g_allocator, true);
    } else if (isStartupEnabled()) {
        // Refresh the absolute executable path after a portable move/update.
        try setStartupEnabled(g_allocator, true);
    }
}

fn startupWasConfigured() bool {
    var key: api.HKEY = undefined;
    if (api.RegOpenKeyExA(api.HKEY_CURRENT_USER, SETTINGS_KEY, 0, api.KEY_QUERY_VALUE, &key) != api.ERROR_SUCCESS) {
        return false;
    }
    defer _ = api.RegCloseKey(key);
    return api.RegQueryValueExA(key, CONFIGURED_VALUE, null, null, null, null) == api.ERROR_SUCCESS;
}

fn markStartupConfigured() !void {
    var key: api.HKEY = undefined;
    if (api.RegCreateKeyExA(
        api.HKEY_CURRENT_USER,
        SETTINGS_KEY,
        0,
        null,
        0,
        api.KEY_SET_VALUE,
        null,
        &key,
        null,
    ) != api.ERROR_SUCCESS) return error.RegistryOpenFailed;
    defer _ = api.RegCloseKey(key);

    var configured: u32 = 1;
    if (api.RegSetValueExA(
        key,
        CONFIGURED_VALUE,
        0,
        api.REG_DWORD,
        @ptrCast(&configured),
        @sizeOf(u32),
    ) != api.ERROR_SUCCESS) return error.RegistryWriteFailed;
}

fn addTrayIcon() !void {
    const window = g_window orelse return error.NoLifecycleWindow;
    g_icon_data = std.mem.zeroes(api.NOTIFYICONDATAA);
    g_icon_data.cbSize = @sizeOf(api.NOTIFYICONDATAA);
    g_icon_data.hWnd = window;
    g_icon_data.uID = TRAY_ID;
    g_icon_data.uFlags = api.NIF_MESSAGE | api.NIF_ICON | api.NIF_TIP;
    g_icon_data.uCallbackMessage = TRAY_CALLBACK;
    g_icon_data.hIcon = api.LoadIconA(null, api.makeIntResource(api.IDI_APPLICATION));
    setTooltip(if (g_enabled) "SysInput - Enabled" else "SysInput - Paused");
    if (api.Shell_NotifyIconA(api.NIM_ADD, &g_icon_data) == 0) return error.TrayIconCreationFailed;
    g_icon_added = true;
    g_icon_data.uTimeoutOrVersion = api.NOTIFYICON_VERSION_4;
    _ = api.Shell_NotifyIconA(api.NIM_SETVERSION, &g_icon_data);
}

fn setTooltip(text: []const u8) void {
    @memset(&g_icon_data.szTip, 0);
    const len = @min(text.len, g_icon_data.szTip.len - 1);
    @memcpy(g_icon_data.szTip[0..len], text[0..len]);
}

fn updateTrayTooltip() void {
    if (!g_icon_added) return;
    g_icon_data.uFlags = api.NIF_TIP;
    setTooltip(if (g_enabled) "SysInput - Enabled" else "SysInput - Paused");
    _ = api.Shell_NotifyIconA(api.NIM_MODIFY, &g_icon_data);
}

fn toggleEnabled() void {
    const desired = !g_enabled;
    if (g_callbacks.set_enabled(desired)) {
        g_enabled = desired;
        updateTrayTooltip();
    }
}

fn showTrayMenu(hwnd: api.HWND) void {
    const menu = api.CreatePopupMenu() orelse return;
    defer _ = api.DestroyMenu(menu);

    const toggle_label = if (g_enabled) "Pause predictions" else "Enable predictions";
    _ = api.AppendMenuA(menu, api.MF_STRING, MENU_TOGGLE, toggle_label);
    const startup_flags: api.UINT = api.MF_STRING | if (isStartupEnabled()) @as(api.UINT, api.MF_CHECKED) else 0;
    _ = api.AppendMenuA(menu, startup_flags, MENU_STARTUP, "Start with Windows");
    _ = api.AppendMenuA(menu, api.MF_SEPARATOR, 0, null);
    _ = api.AppendMenuA(menu, api.MF_STRING, MENU_EXIT, "Exit");

    var point: api.POINT = undefined;
    if (api.GetCursorPos(&point) == 0) return;
    _ = api.SetForegroundWindow(hwnd);
    const command = api.TrackPopupMenu(
        menu,
        api.TPM_RIGHTBUTTON | api.TPM_RETURNCMD,
        point.x,
        point.y,
        0,
        hwnd,
        null,
    );
    _ = api.PostMessageA(hwnd, api.WM_NULL, 0, 0);

    switch (command) {
        MENU_TOGGLE => toggleEnabled(),
        MENU_STARTUP => setStartupEnabled(g_allocator, !isStartupEnabled()) catch {},
        MENU_EXIT => api.PostQuitMessage(0),
        else => {},
    }
}

fn windowProc(hwnd: api.HWND, message: api.UINT, w_param: api.WPARAM, l_param: api.LPARAM) callconv(.C) api.LRESULT {
    switch (message) {
        TRAY_CALLBACK => {
            const event: u32 = @truncate(@as(usize, @bitCast(l_param)));
            if (event == api.WM_RBUTTONUP or event == api.WM_CONTEXTMENU) showTrayMenu(hwnd);
            if (event == api.WM_LBUTTONDBLCLK) toggleEnabled();
            return 0;
        },
        api.WM_CLOSE => {
            api.PostQuitMessage(0);
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, message, w_param, l_param),
    }
}
