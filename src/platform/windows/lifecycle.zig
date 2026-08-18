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
const APP_ICON_ID = 101;
const MENU_TOGGLE = 1001;
const MENU_STARTUP = 1002;
const MENU_EXIT = 1003;
const MENU_SETTINGS = 1004;
const MENU_EXCLUDE_CURRENT = 1005;
const MENU_PAUSE = 1006;
const MENU_FEEDBACK = 1007;
const MENU_ABOUT = 1008;
const PAUSE_TIMER_ID: usize = 1;
const PAUSE_DURATION_MS: api.UINT = 30 * 60 * 1000;

pub const Options = struct {
    background: bool = false,
    startup_write: bool = true,
    portable: bool = false,

    pub fn parse(args: []const []const u8) Options {
        var result = Options{};
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--background")) result.background = true;
            if (std.mem.eql(u8, arg, "--no-startup-write")) result.startup_write = false;
            if (std.mem.eql(u8, arg, "--portable")) result.portable = true;
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
    startup_changed: *const fn (bool) void,
    open_settings: *const fn () void,
    open_about: *const fn () void,
    exclude_window: *const fn (?api.HWND) bool,
    pause_input: *const fn () bool,
    resume_input: *const fn () bool,
};

var g_allocator: std.mem.Allocator = undefined;
var g_instance: ?api.HINSTANCE = null;
var g_window: ?api.HWND = null;
var g_window_class: api.ATOM = 0;
var g_icon_data: api.NOTIFYICONDATAA = undefined;
var g_icon_added = false;
var g_enabled = true;
var g_paused = false;
var g_portable = false;
var g_callbacks: Callbacks = undefined;
var g_last_external_foreground: ?api.HWND = null;

pub fn init(
    allocator: std.mem.Allocator,
    instance: api.HINSTANCE,
    options: Options,
    initial_enabled: bool,
    callbacks: Callbacks,
) !void {
    if (g_window != null) return;
    g_allocator = allocator;
    g_instance = instance;
    g_callbacks = callbacks;
    g_enabled = initial_enabled;
    g_paused = false;
    g_portable = options.portable;

    const application_icon = api.LoadIconA(instance, api.makeIntResource(APP_ICON_ID));
    const wc = api.WNDCLASSEX{
        .cbSize = @sizeOf(api.WNDCLASSEX),
        .style = 0,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = application_icon,
        .hCursor = null,
        .hbrBackground = @ptrCast(api.GetStockObject(api.WHITE_BRUSH).?),
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS,
        .hIconSm = application_icon,
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
    if (options.startup_write) initializeStartupPreference(options.portable) catch {};
    g_callbacks.startup_changed(isStartupEnabled());
    _ = options.background;
}

pub fn deinit() void {
    cancelPauseTimer();
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

pub fn syncEnabled(enabled: bool) void {
    if (g_window == null) return;
    cancelPauseTimer();
    g_enabled = enabled;
    g_paused = false;
    updateTrayTooltip();
}

pub fn startupCommand(allocator: std.mem.Allocator, executable_path: []const u8, portable: bool) ![:0]u8 {
    if (portable) return std.fmt.allocPrintZ(allocator, "\"{s}\" --background --portable", .{executable_path});
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

pub fn lastExternalWindow() ?api.HWND {
    return g_last_external_foreground;
}

pub fn setStartupEnabled(allocator: std.mem.Allocator, enabled: bool, portable: bool) !void {
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
    const command = try startupCommand(allocator, executable, portable);
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

fn initializeStartupPreference(portable: bool) !void {
    if (!startupWasConfigured()) {
        try setStartupEnabled(g_allocator, true, portable);
    } else if (isStartupEnabled()) {
        // Refresh the absolute executable path after a portable move/update.
        try setStartupEnabled(g_allocator, true, portable);
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
    g_icon_data.hIcon = api.LoadIconA(g_instance, api.makeIntResource(APP_ICON_ID)) orelse
        api.LoadIconA(null, api.makeIntResource(api.IDI_APPLICATION));
    setTooltip(tooltipText());
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
    setTooltip(tooltipText());
    _ = api.Shell_NotifyIconA(api.NIM_MODIFY, &g_icon_data);
}

fn tooltipText() []const u8 {
    return trayTooltip(g_enabled, g_paused);
}

pub fn trayTooltip(enabled: bool, paused: bool) []const u8 {
    if (paused) return "SysInput - Paused for 30 minutes";
    return if (enabled) "SysInput - Enabled" else "SysInput - Disabled";
}

fn cancelPauseTimer() void {
    if (!g_paused) return;
    if (g_window) |window| _ = api.KillTimer(window, PAUSE_TIMER_ID);
    g_paused = false;
}

fn toggleEnabled() void {
    const desired = !g_enabled;
    if (g_callbacks.set_enabled(desired)) {
        cancelPauseTimer();
        g_enabled = desired;
        g_paused = false;
        updateTrayTooltip();
    }
}

fn pauseForThirtyMinutes() void {
    const window = g_window orelse return;
    if (!g_enabled or !g_callbacks.pause_input()) return;
    if (api.SetTimer(window, PAUSE_TIMER_ID, PAUSE_DURATION_MS, null) == 0) {
        _ = g_callbacks.resume_input();
        return;
    }
    g_enabled = false;
    g_paused = true;
    updateTrayTooltip();
}

fn resumeAfterPause() void {
    if (!g_paused) return;
    _ = api.KillTimer(g_window, PAUSE_TIMER_ID);
    if (g_callbacks.resume_input()) g_enabled = true;
    g_paused = false;
    updateTrayTooltip();
}

fn showTrayMenu(hwnd: api.HWND) void {
    captureExternalForeground();
    const menu = api.CreatePopupMenu() orelse return;
    defer _ = api.DestroyMenu(menu);

    const enabled_flags: api.UINT = api.MF_STRING | if (g_enabled) @as(api.UINT, api.MF_CHECKED) else 0;
    _ = api.AppendMenuA(menu, enabled_flags, MENU_TOGGLE, "Predictions enabled");
    _ = api.AppendMenuA(menu, api.MF_STRING, MENU_SETTINGS, "Settings...");
    const pause_flags: api.UINT = api.MF_STRING | if (g_enabled) 0 else @as(api.UINT, api.MF_GRAYED);
    _ = api.AppendMenuA(menu, pause_flags, MENU_PAUSE, "Pause for 30 minutes");
    const exclude_flags: api.UINT = api.MF_STRING | if (g_last_external_foreground == null) @as(api.UINT, api.MF_GRAYED) else 0;
    _ = api.AppendMenuA(menu, exclude_flags, MENU_EXCLUDE_CURRENT, "Exclude current application");
    _ = api.AppendMenuA(menu, api.MF_STRING | api.MF_GRAYED, MENU_FEEDBACK, "Feedback... (coming soon)");
    const startup_flags: api.UINT = api.MF_STRING | if (isStartupEnabled()) @as(api.UINT, api.MF_CHECKED) else 0;
    _ = api.AppendMenuA(menu, startup_flags, MENU_STARTUP, "Start with Windows");
    _ = api.AppendMenuA(menu, api.MF_STRING, MENU_ABOUT, "About");
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
        MENU_SETTINGS => g_callbacks.open_settings(),
        MENU_PAUSE => pauseForThirtyMinutes(),
        MENU_EXCLUDE_CURRENT => _ = g_callbacks.exclude_window(g_last_external_foreground),
        MENU_STARTUP => {
            const desired = !isStartupEnabled();
            setStartupEnabled(g_allocator, desired, g_portable) catch return;
            g_callbacks.startup_changed(desired);
        },
        MENU_ABOUT => g_callbacks.open_about(),
        MENU_EXIT => api.PostQuitMessage(0),
        else => {},
    }
}

fn captureExternalForeground() void {
    const foreground = api.GetForegroundWindow();
    if (foreground) |candidate| {
        var pid: api.DWORD = 0;
        _ = api.GetWindowThreadProcessId(candidate, &pid);
        if (candidate != g_window and pid != api.GetCurrentProcessId()) g_last_external_foreground = candidate;
    }
}

fn windowProc(hwnd: api.HWND, message: api.UINT, w_param: api.WPARAM, l_param: api.LPARAM) callconv(.C) api.LRESULT {
    switch (message) {
        TRAY_CALLBACK => {
            captureExternalForeground();
            const event: u32 = @truncate(@as(usize, @bitCast(l_param)));
            if (event == api.WM_RBUTTONUP or event == api.WM_CONTEXTMENU) showTrayMenu(hwnd);
            if (event == api.WM_LBUTTONUP or event == api.WM_LBUTTONDBLCLK) g_callbacks.open_settings();
            return 0;
        },
        api.WM_CLOSE => {
            api.PostQuitMessage(0);
            return 0;
        },
        api.WM_TIMER => {
            if (w_param == PAUSE_TIMER_ID) resumeAfterPause();
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, message, w_param, l_param),
    }
}
