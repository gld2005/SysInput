const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const runtime_settings = sysinput.core.runtime_settings;

const WINDOW_CLASS = "SysInputAppearanceWindow";
const WINDOW_TITLE = "Candidate appearance";
const APP_ICON_ID = 101;
const ID_THEME = 4101;
const ID_ACCENT = 4102;
const ID_DENSITY = 4103;
const ID_CLOSE = 4104;

pub const Callback = *const fn () void;

var instance: api.HINSTANCE = undefined;
var settings: *runtime_settings.Store = undefined;
var settings_changed: Callback = undefined;
var window: ?api.HWND = null;
var window_class: api.ATOM = 0;
var font: ?api.HFONT = null;
var theme_combo: ?api.HWND = null;
var accent_combo: ?api.HWND = null;
var density_combo: ?api.HWND = null;

pub fn init(module_instance: api.HINSTANCE, store: *runtime_settings.Store, callback: Callback) !void {
    instance = module_instance;
    settings = store;
    settings_changed = callback;
    font = api.CreateFontA(-16, 0, 0, 0, api.FW_NORMAL, 0, 0, 0, api.ANSI_CHARSET, api.OUT_DEFAULT_PRECIS, api.CLIP_DEFAULT_PRECIS, api.CLEARTYPE_QUALITY, api.DEFAULT_PITCH, "Segoe UI");
    const icon = api.LoadIconA(instance, api.makeIntResource(APP_ICON_ID));
    const wc = api.WNDCLASSEX{
        .cbSize = @sizeOf(api.WNDCLASSEX),
        .style = 0,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = icon,
        .hCursor = api.LoadCursorA(null, api.makeIntResource(api.IDC_ARROW)),
        .hbrBackground = @ptrCast(api.GetStockObject(api.WHITE_BRUSH).?),
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS,
        .hIconSm = icon,
    };
    window_class = api.RegisterClassExA(&wc);
    if (window_class == 0) return error.AppearanceClassRegistrationFailed;
}

pub fn deinit() void {
    if (window) |handle| _ = api.DestroyWindow(handle);
    window = null;
    if (window_class != 0) _ = api.UnregisterClassA(WINDOW_CLASS, instance);
    window_class = 0;
    if (font) |handle| _ = api.DeleteObject(handle);
    font = null;
}

pub fn show() void {
    if (window == null) createWindow() catch return;
    refresh();
    _ = api.ShowWindow(window.?, api.SW_SHOW);
    _ = api.SetForegroundWindow(window.?);
}

fn createWindow() !void {
    window = api.CreateWindowExA(api.WS_EX_APPWINDOW, WINDOW_CLASS, WINDOW_TITLE, api.WS_OVERLAPPEDWINDOW, api.CW_USEDEFAULT, api.CW_USEDEFAULT, 390, 270, null, null, instance, null) orelse return error.AppearanceWindowCreationFailed;
    const parent = window.?;
    _ = try createControl("STATIC", "Theme", 24, 28, 110, 24, parent, 0, 0);
    theme_combo = try createControl("COMBOBOX", "", 150, 24, 200, 150, parent, ID_THEME, api.CBS_DROPDOWNLIST | api.WS_TABSTOP);
    addItems(theme_combo.?, &.{ "Follow Windows", "Light", "Dark" });
    _ = try createControl("STATIC", "Accent", 24, 76, 110, 24, parent, 0, 0);
    accent_combo = try createControl("COMBOBOX", "", 150, 72, 200, 170, parent, ID_ACCENT, api.CBS_DROPDOWNLIST | api.WS_TABSTOP);
    addItems(accent_combo.?, &.{ "Windows accent", "Blue", "Teal", "Purple" });
    _ = try createControl("STATIC", "Density", 24, 124, 110, 24, parent, 0, 0);
    density_combo = try createControl("COMBOBOX", "", 150, 120, 200, 120, parent, ID_DENSITY, api.CBS_DROPDOWNLIST | api.WS_TABSTOP);
    addItems(density_combo.?, &.{ "Compact", "Comfortable" });
    _ = try createControl("STATIC", "Changes apply to the next candidate immediately.", 24, 170, 326, 22, parent, 0, 0);
    _ = try createControl("BUTTON", "Close", 270, 198, 80, 28, parent, ID_CLOSE, api.BS_PUSHBUTTON | api.WS_TABSTOP);
    refresh();
}

fn createControl(class_name: [*:0]const u8, title: [*:0]const u8, x: c_int, y: c_int, width: c_int, height: c_int, parent: api.HWND, id: usize, style: api.DWORD) !api.HWND {
    const handle = api.CreateWindowExA(0, class_name, title, api.WS_CHILD | api.WS_VISIBLE | style, x, y, width, height, parent, if (id == 0) null else @ptrFromInt(id), instance, null) orelse return error.AppearanceControlCreationFailed;
    if (font) |control_font| _ = api.SendMessageA(handle, api.WM_SETFONT, @intFromPtr(control_font), 1);
    return handle;
}

fn addItems(combo: api.HWND, items: []const [*:0]const u8) void {
    for (items) |item| _ = api.SendMessageA(combo, api.CB_ADDSTRING, 0, @bitCast(@intFromPtr(item)));
}

fn refresh() void {
    const value = settings.appearance();
    if (theme_combo) |combo| _ = api.SendMessageA(combo, api.CB_SETCURSEL, @intFromEnum(value.theme), 0);
    if (accent_combo) |combo| _ = api.SendMessageA(combo, api.CB_SETCURSEL, @intFromEnum(value.accent), 0);
    if (density_combo) |combo| _ = api.SendMessageA(combo, api.CB_SETCURSEL, @intFromEnum(value.density), 0);
}

fn selection(combo: ?api.HWND) ?u8 {
    const handle = combo orelse return null;
    const result = api.SendMessageA(handle, api.CB_GETCURSEL, 0, 0);
    if (result == api.CB_ERR or result < 0 or result > 255) return null;
    return @intCast(result);
}

fn save() void {
    const theme_value = selection(theme_combo) orelse return;
    const accent_value = selection(accent_combo) orelse return;
    const density_value = selection(density_combo) orelse return;
    const value = runtime_settings.Appearance{
        .theme = std.meta.intToEnum(runtime_settings.Theme, theme_value) catch return,
        .accent = std.meta.intToEnum(runtime_settings.Accent, accent_value) catch return,
        .density = std.meta.intToEnum(runtime_settings.Density, density_value) catch return,
    };
    settings.setAppearanceAndSave(value) catch {
        refresh();
        return;
    };
    settings_changed();
}

fn windowProc(hwnd: api.HWND, message: api.UINT, w_param: api.WPARAM, l_param: api.LPARAM) callconv(.C) api.LRESULT {
    switch (message) {
        api.WM_COMMAND => {
            const id: usize = w_param & 0xffff;
            const notification: usize = (w_param >> 16) & 0xffff;
            if (notification == api.CBN_SELCHANGE and (id == ID_THEME or id == ID_ACCENT or id == ID_DENSITY)) save();
            if (notification == api.BN_CLICKED and id == ID_CLOSE) _ = api.ShowWindow(hwnd, api.SW_HIDE);
            return 0;
        },
        api.WM_CLOSE => {
            _ = api.ShowWindow(hwnd, api.SW_HIDE);
            return 0;
        },
        api.WM_DESTROY => {
            window = null;
            theme_combo = null;
            accent_combo = null;
            density_combo = null;
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, message, w_param, l_param),
    }
}
