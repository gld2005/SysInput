const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const runtime_settings = sysinput.core.runtime_settings;
const data_paths = sysinput.core.data_paths;
const data_location = sysinput.core.data_location;
const exclusions = sysinput.core.application_exclusions;
const abbreviation_window = sysinput.ui.abbreviation_window;
const corpus_window = sysinput.ui.corpus_window;

const WINDOW_CLASS = "SysInputSettingsWindow";
const WINDOW_TITLE = "SysInput Settings";
const APP_ICON_ID = 101;

const ID_NAVIGATION = 1999;
const ID_ENABLED = 2001;
const ID_STARTUP = 2002;
const ID_WORD = 2010;
const ID_NEXT = 2011;
const ID_PHRASE = 2012;
const ID_SENTENCE = 2013;
const ID_LEARNING = 2014;
const ID_SAFE_ARROWS = 2020;
const ID_ABBREVIATIONS = 2021;
const ID_MANAGE_ABBREVIATIONS = 2022;
const ID_AUTO_ABBREVIATIONS = 2023;
const ID_ABBREVIATION_PREFIX = 2024;
const ID_SET_PREFIX = 2025;
const ID_CORPUS = 2026;
const ID_MANAGE_CORPUS = 2027;
const ID_APP_LIST = 2030;
const ID_ADD_CURRENT = 2031;
const ID_BROWSE = 2032;
const ID_TOGGLE_APP = 2033;
const ID_REMOVE_APP = 2034;
const ID_THEME = 2040;
const ID_ACCENT = 2041;
const ID_DENSITY = 2042;
const ID_DATA_DIRECTORY = 2050;
const ID_BROWSE_DATA = 2051;
const ID_COPY_DATA = 2052;
const ID_RESTORE_DATA = 2053;
const ID_APPLY_DATA = 2054;

pub const Page = enum(u8) { general, prediction, appearance, keyboard, applications, data, about };
const page_count = @typeInfo(Page).@"enum".fields.len;

pub const Callbacks = struct {
    set_enabled: *const fn (bool) bool,
    set_startup: *const fn (bool) bool,
    settings_changed: *const fn () void,
    add_current_application: *const fn () bool,
};

const Binding = struct { id: usize, feature: runtime_settings.Feature };
const bindings = [_]Binding{
    .{ .id = ID_ENABLED, .feature = .enabled },
    .{ .id = ID_STARTUP, .feature = .start_with_windows },
    .{ .id = ID_WORD, .feature = .word_completion },
    .{ .id = ID_NEXT, .feature = .next_word_prediction },
    .{ .id = ID_PHRASE, .feature = .phrase_completion },
    .{ .id = ID_SENTENCE, .feature = .sentence_prediction },
    .{ .id = ID_LEARNING, .feature = .personal_learning },
    .{ .id = ID_SAFE_ARROWS, .feature = .safe_arrow_mode },
    .{ .id = ID_ABBREVIATIONS, .feature = .abbreviation_expansion },
    .{ .id = ID_AUTO_ABBREVIATIONS, .feature = .abbreviation_auto_expand },
    .{ .id = ID_CORPUS, .feature = .corpus_prediction },
};

const PageControl = struct { handle: api.HWND, page: Page };

var allocator: std.mem.Allocator = undefined;
var instance: api.HINSTANCE = undefined;
var settings: *runtime_settings.Store = undefined;
var exclusion_store: *exclusions.Store = undefined;
var callbacks: Callbacks = undefined;
var window: ?api.HWND = null;
var window_class: api.ATOM = 0;
var settings_font: ?api.HFONT = null;
var navigation: ?api.HWND = null;
var page_title: ?api.HWND = null;
var status_label: ?api.HWND = null;
var list_box: ?api.HWND = null;
var abbreviation_prefix: ?api.HWND = null;
var theme_combo: ?api.HWND = null;
var accent_combo: ?api.HWND = null;
var density_combo: ?api.HWND = null;
var paths: *const data_paths.DataPaths = undefined;
var data_directory: ?api.HWND = null;
var copy_data: ?api.HWND = null;
var controls: [bindings.len]?api.HWND = [_]?api.HWND{null} ** bindings.len;
var page_controls: [48]PageControl = undefined;
var page_control_count: usize = 0;
var current_page: Page = .general;

pub fn init(ui_allocator: std.mem.Allocator, module_instance: api.HINSTANCE, runtime_store: *runtime_settings.Store, applications: *exclusions.Store, runtime_paths: *const data_paths.DataPaths, ui_callbacks: Callbacks) !void {
    allocator = ui_allocator;
    instance = module_instance;
    settings = runtime_store;
    exclusion_store = applications;
    paths = runtime_paths;
    callbacks = ui_callbacks;
    settings_font = api.CreateFontA(-16, 0, 0, 0, api.FW_NORMAL, 0, 0, 0, api.ANSI_CHARSET, api.OUT_DEFAULT_PRECIS, api.CLIP_DEFAULT_PRECIS, api.CLEARTYPE_QUALITY, api.DEFAULT_PITCH, "Segoe UI");
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
    if (window_class == 0) return error.SettingsClassRegistrationFailed;
}

pub fn deinit() void {
    if (window) |handle| _ = api.DestroyWindow(handle);
    window = null;
    if (window_class != 0) _ = api.UnregisterClassA(WINDOW_CLASS, instance);
    window_class = 0;
    if (settings_font) |font| _ = api.DeleteObject(font);
    settings_font = null;
}

pub fn show() void {
    showPage(.general);
}

pub fn showPage(page: Page) void {
    if (window == null) createWindow() catch return;
    refresh();
    switchPage(page);
    _ = api.ShowWindow(window.?, api.SW_SHOW);
    _ = api.SetForegroundWindow(window.?);
    _ = api.UpdateWindow(window.?);
}

pub fn refresh() void {
    refreshSettings();
    refreshApplications();
    refreshAppearance();
}

pub fn refreshApplications() void {
    const list = list_box orelse return;
    _ = api.SendMessageA(list, api.LB_RESETCONTENT, 0, 0);
    var copied: [exclusions.MAX_ENTRIES]exclusions.Entry = undefined;
    const count = exclusion_store.copyEntries(&copied);
    for (copied[0..count]) |*entry| {
        var row: [exclusions.MAX_PATH_BYTES + 8:0]u8 = undefined;
        const formatted = std.fmt.bufPrint(row[0 .. row.len - 1], "[{s}] {s}", .{ if (entry.enabled) "x" else " ", entry.pathSlice() }) catch continue;
        row[formatted.len] = 0;
        _ = api.SendMessageA(list, api.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&row)));
    }
}

fn createWindow() !void {
    window = api.CreateWindowExA(api.WS_EX_APPWINDOW, WINDOW_CLASS, WINDOW_TITLE, api.WS_OVERLAPPEDWINDOW, api.CW_USEDEFAULT, api.CW_USEDEFAULT, 620, 480, null, null, instance, null) orelse return error.SettingsWindowCreationFailed;
    try createControls(window.?);
}

fn createControls(parent: api.HWND) !void {
    navigation = try createControl("LISTBOX", "", api.LBS_NOTIFY | api.WS_TABSTOP, 14, 42, 124, 360, parent, ID_NAVIGATION, null);
    for ([_][*:0]const u8{ "General", "Prediction", "Appearance", "Keyboard", "Applications", "Data", "About" }) |name| {
        _ = api.SendMessageA(navigation.?, api.LB_ADDSTRING, 0, @bitCast(@intFromPtr(name)));
    }
    page_title = try createControl("STATIC", "General", 0, 158, 18, 420, 26, parent, 0, null);

    controls[0] = try createControl("BUTTON", "Predictions enabled", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 160, 62, 360, 26, parent, ID_ENABLED, .general);
    controls[1] = try createControl("BUTTON", "Start with Windows", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 160, 98, 360, 26, parent, ID_STARTUP, .general);
    _ = try createControl("STATIC", "SysInput activates only for a Windows English keyboard layout.", 0, 160, 148, 410, 42, parent, 0, .general);

    controls[2] = try pageCheckbox(parent, "Word completion", 60, ID_WORD, .prediction);
    controls[3] = try pageCheckbox(parent, "Next-word prediction", 90, ID_NEXT, .prediction);
    controls[4] = try pageCheckbox(parent, "Phrase completion", 120, ID_PHRASE, .prediction);
    controls[5] = try pageCheckbox(parent, "Sentence prediction", 150, ID_SENTENCE, .prediction);
    controls[6] = try pageCheckbox(parent, "Personal learning", 180, ID_LEARNING, .prediction);
    controls[8] = try pageCheckbox(parent, "Abbreviation expansion", 210, ID_ABBREVIATIONS, .prediction);
    controls[9] = try pageCheckbox(parent, "Auto-expand explicit prefix", 240, ID_AUTO_ABBREVIATIONS, .prediction);
    abbreviation_prefix = try createControl("EDIT", ";", api.ES_AUTOHSCROLL | api.WS_TABSTOP, 390, 238, 34, 24, parent, ID_ABBREVIATION_PREFIX, .prediction);
    _ = try createControl("BUTTON", "Set", api.BS_PUSHBUTTON | api.WS_TABSTOP, 430, 237, 52, 26, parent, ID_SET_PREFIX, .prediction);
    controls[10] = try pageCheckbox(parent, "Imported corpus prediction", 270, ID_CORPUS, .prediction);
    _ = try createControl("BUTTON", "Manage abbreviations...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 160, 312, 170, 28, parent, ID_MANAGE_ABBREVIATIONS, .prediction);
    _ = try createControl("BUTTON", "Manage corpus...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 342, 312, 150, 28, parent, ID_MANAGE_CORPUS, .prediction);

    _ = try createControl("STATIC", "Theme", 0, 160, 66, 130, 24, parent, 0, .appearance);
    theme_combo = try createControl("COMBOBOX", "", api.CBS_DROPDOWNLIST | api.WS_TABSTOP, 310, 62, 220, 150, parent, ID_THEME, .appearance);
    addComboItems(theme_combo.?, &.{ "Follow Windows", "Light", "Dark" });
    _ = try createControl("STATIC", "Accent", 0, 160, 114, 130, 24, parent, 0, .appearance);
    accent_combo = try createControl("COMBOBOX", "", api.CBS_DROPDOWNLIST | api.WS_TABSTOP, 310, 110, 220, 170, parent, ID_ACCENT, .appearance);
    addComboItems(accent_combo.?, &.{ "Windows accent", "Blue", "Teal", "Purple" });
    _ = try createControl("STATIC", "Density", 0, 160, 162, 130, 24, parent, 0, .appearance);
    density_combo = try createControl("COMBOBOX", "", api.CBS_DROPDOWNLIST | api.WS_TABSTOP, 310, 158, 220, 120, parent, ID_DENSITY, .appearance);
    addComboItems(density_combo.?, &.{ "Compact", "Comfortable" });
    _ = try createControl("STATIC", "High Contrast always overrides custom colors. Changes apply to the next candidate.", 0, 160, 220, 390, 52, parent, 0, .appearance);

    controls[7] = try pageCheckbox(parent, "Safe arrow mode (recommended)", 64, ID_SAFE_ARROWS, .keyboard);
    _ = try createControl("STATIC", "Tab accepts the next chunk. Ctrl+Right accepts one word. Ordinary arrow keys remain available to the active application.", 0, 160, 112, 400, 70, parent, 0, .keyboard);

    list_box = try createControl("LISTBOX", "", api.WS_VSCROLL | api.LBS_NOTIFY | api.WS_TABSTOP, 160, 58, 420, 220, parent, ID_APP_LIST, .applications);
    _ = try createControl("BUTTON", "Add current", api.BS_PUSHBUTTON | api.WS_TABSTOP, 160, 294, 100, 28, parent, ID_ADD_CURRENT, .applications);
    _ = try createControl("BUTTON", "Browse...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 270, 294, 90, 28, parent, ID_BROWSE, .applications);
    _ = try createControl("BUTTON", "Enable / disable", api.BS_PUSHBUTTON | api.WS_TABSTOP, 370, 294, 120, 28, parent, ID_TOGGLE_APP, .applications);
    _ = try createControl("BUTTON", "Remove", api.BS_PUSHBUTTON | api.WS_TABSTOP, 500, 294, 80, 28, parent, ID_REMOVE_APP, .applications);

    _ = try createControl("STATIC", "All SysInput data stays local.", 0, 160, 58, 400, 24, parent, 0, .data);
    _ = try createControl("STATIC", "Data directory:", 0, 160, 96, 400, 22, parent, 0, .data);
    data_directory = try createWideEdit(parent, paths.root, 160, 120, 310, 26, ID_DATA_DIRECTORY, .data);
    const browse_data = try createControl("BUTTON", "Browse...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 480, 120, 98, 26, parent, ID_BROWSE_DATA, .data);
    copy_data = try createControl("BUTTON", "Copy existing data to the new directory (recommended)", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 160, 162, 418, 26, parent, ID_COPY_DATA, .data);
    _ = api.SendMessageA(copy_data.?, api.BM_SETCHECK, api.BST_CHECKED, 0);
    const restore_data = try createControl("BUTTON", "Restore default", api.BS_PUSHBUTTON | api.WS_TABSTOP, 160, 208, 120, 28, parent, ID_RESTORE_DATA, .data);
    const apply_data = try createControl("BUTTON", "Apply", api.BS_PUSHBUTTON | api.WS_TABSTOP, 470, 208, 108, 28, parent, ID_APPLY_DATA, .data);
    _ = try createControl("STATIC", "The change is applied safely the next time SysInput starts. The old data is not deleted.", 0, 160, 258, 410, 50, parent, 0, .data);
    if (paths.mode == .portable) {
        _ = api.EnableWindow(data_directory.?, 0);
        _ = api.EnableWindow(browse_data, 0);
        _ = api.EnableWindow(copy_data.?, 0);
        _ = api.EnableWindow(restore_data, 0);
        _ = api.EnableWindow(apply_data, 0);
    }

    _ = try createControl("STATIC", "SysInput v0.2.0 RC2", 0, 160, 64, 400, 28, parent, 0, .about);
    _ = try createControl("STATIC", "Lightweight English input assistance for Windows. No cloud sync, telemetry, grammar correction, or online model.", 0, 160, 108, 400, 72, parent, 0, .about);
    _ = try createControl("STATIC", "Feedback is planned and currently unavailable.", 0, 160, 204, 400, 28, parent, 0, .about);

    status_label = try createControl("STATIC", "", 0, 158, 410, 420, 22, parent, 0, null);
    refresh();
    switchPage(.general);
    switch (paths.location_status) {
        .applied => setStatus("Data directory changed successfully. The previous data was kept."),
        .failed => setStatus("The requested data-directory change failed; the previous directory is still in use."),
        .unchanged => if (paths.mode == .portable) setStatus("Portable mode always uses the data directory beside SysInput.exe."),
    }
}

fn createWideEdit(parent: api.HWND, value: []const u8, x: c_int, y: c_int, width: c_int, height: c_int, id: usize, page: Page) !api.HWND {
    const wide_value = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(wide_value);
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const handle = api.CreateWindowExW(api.WS_EX_CLIENTEDGE, edit_class, wide_value.ptr, api.WS_CHILD | api.ES_AUTOHSCROLL | api.WS_TABSTOP, x, y, width, height, parent, @ptrFromInt(id), instance, null) orelse return error.SettingsControlCreationFailed;
    if (settings_font) |font| _ = api.SendMessageA(handle, api.WM_SETFONT, @intFromPtr(font), 1);
    if (page_control_count >= page_controls.len) return error.TooManySettingsControls;
    page_controls[page_control_count] = .{ .handle = handle, .page = page };
    page_control_count += 1;
    return handle;
}

fn pageCheckbox(parent: api.HWND, title: [*:0]const u8, y: c_int, id: usize, page: Page) !api.HWND {
    return createControl("BUTTON", title, api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 160, y, 370, 26, parent, id, page);
}

fn createControl(class_name: [*:0]const u8, title: [*:0]const u8, style: api.DWORD, x: c_int, y: c_int, width: c_int, height: c_int, parent: api.HWND, id: usize, page: ?Page) !api.HWND {
    const extended: api.DWORD = if (std.mem.eql(u8, std.mem.span(class_name), "LISTBOX")) api.WS_EX_CLIENTEDGE else 0;
    const visible: api.DWORD = if (page == null) api.WS_VISIBLE else 0;
    const handle = api.CreateWindowExA(extended, class_name, title, api.WS_CHILD | visible | style, x, y, width, height, parent, if (id == 0) null else @ptrFromInt(id), instance, null) orelse return error.SettingsControlCreationFailed;
    if (settings_font) |font| _ = api.SendMessageA(handle, api.WM_SETFONT, @intFromPtr(font), 1);
    if (page) |owned_page| {
        if (page_control_count >= page_controls.len) return error.TooManySettingsControls;
        page_controls[page_control_count] = .{ .handle = handle, .page = owned_page };
        page_control_count += 1;
    }
    return handle;
}

fn addComboItems(combo: api.HWND, items: []const [*:0]const u8) void {
    for (items) |item| _ = api.SendMessageA(combo, api.CB_ADDSTRING, 0, @bitCast(@intFromPtr(item)));
}

fn pageName(page: Page) [*:0]const u8 {
    return switch (page) {
        .general => "General",
        .prediction => "Prediction",
        .appearance => "Appearance",
        .keyboard => "Keyboard",
        .applications => "Applications",
        .data => "Data",
        .about => "About",
    };
}

fn switchPage(page: Page) void {
    current_page = page;
    for (page_controls[0..page_control_count]) |entry| _ = api.ShowWindow(entry.handle, if (entry.page == page) api.SW_SHOW else api.SW_HIDE);
    if (navigation) |nav| _ = api.SendMessageA(nav, api.LB_SETCURSEL, @intFromEnum(page), 0);
    if (page_title) |title| _ = api.SetWindowTextA(title, pageName(page));
}

fn refreshSettings() void {
    for (bindings, 0..) |binding, index| {
        if (controls[index]) |control| _ = api.SendMessageA(control, api.BM_SETCHECK, if (settings.isEnabled(binding.feature)) api.BST_CHECKED else api.BST_UNCHECKED, 0);
    }
    if (abbreviation_prefix) |control| {
        var text: [2:0]u8 = .{ settings.snapshot().abbreviation_prefix, 0 };
        _ = api.SetWindowTextA(control, &text);
    }
}

fn refreshAppearance() void {
    const value = settings.appearance();
    if (theme_combo) |combo| _ = api.SendMessageA(combo, api.CB_SETCURSEL, @intFromEnum(value.theme), 0);
    if (accent_combo) |combo| _ = api.SendMessageA(combo, api.CB_SETCURSEL, @intFromEnum(value.accent), 0);
    if (density_combo) |combo| _ = api.SendMessageA(combo, api.CB_SETCURSEL, @intFromEnum(value.density), 0);
}

fn setAbbreviationPrefix() void {
    const control = abbreviation_prefix orelse return;
    var text: [3:0]u8 = [_:0]u8{0} ** 3;
    const len = api.GetWindowTextA(control, &text, text.len);
    if (len != 1) {
        setStatus("Prefix must be one punctuation character.");
        refreshSettings();
        return;
    }
    settings.setAbbreviationPrefixAndSave(text[0]) catch {
        setStatus("Prefix must be one punctuation character.");
        refreshSettings();
        return;
    };
    callbacks.settings_changed();
    setStatus("Abbreviation prefix saved.");
}

fn handleCheckbox(id: usize) void {
    for (bindings, 0..) |binding, index| {
        if (binding.id != id) continue;
        const control = controls[index] orelse return;
        const enabled = api.SendMessageA(control, api.BM_GETCHECK, 0, 0) == api.BST_CHECKED;
        const successful = switch (binding.feature) {
            .enabled => callbacks.set_enabled(enabled),
            .start_with_windows => callbacks.set_startup(enabled),
            else => result: {
                settings.setAndSave(binding.feature, enabled) catch break :result false;
                callbacks.settings_changed();
                break :result true;
            },
        };
        if (!successful) {
            setStatus("The setting could not be changed.");
            refreshSettings();
        } else setStatus("Settings saved.");
        return;
    }
}

fn comboSelection(combo: ?api.HWND) ?u8 {
    const handle = combo orelse return null;
    const value = api.SendMessageA(handle, api.CB_GETCURSEL, 0, 0);
    if (value == api.CB_ERR or value < 0 or value > 255) return null;
    return @intCast(value);
}

fn saveAppearance() void {
    const value = runtime_settings.Appearance{
        .theme = std.meta.intToEnum(runtime_settings.Theme, comboSelection(theme_combo) orelse return) catch return,
        .accent = std.meta.intToEnum(runtime_settings.Accent, comboSelection(accent_combo) orelse return) catch return,
        .density = std.meta.intToEnum(runtime_settings.Density, comboSelection(density_combo) orelse return) catch return,
    };
    settings.setAppearanceAndSave(value) catch {
        setStatus("Appearance could not be saved.");
        refreshAppearance();
        return;
    };
    callbacks.settings_changed();
    setStatus("Appearance saved.");
}

fn setDirectoryText(value: []const u8) void {
    const control = data_directory orelse return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, value) catch {
        setStatus("The directory contains unsupported text.");
        return;
    };
    defer allocator.free(wide);
    _ = api.SetWindowTextW(control, wide.ptr);
}

fn readDirectoryText() ![]u8 {
    const control = data_directory orelse return error.NoDataDirectoryControl;
    var wide: [data_location.MAX_PATH_BYTES + 1:0]u16 = [_:0]u16{0} ** (data_location.MAX_PATH_BYTES + 1);
    const length = api.GetWindowTextW(control, &wide, @intCast(wide.len));
    if (length <= 0) return error.InvalidDataDirectory;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..@intCast(length)]);
}

fn browseDataDirectory() void {
    if (paths.mode == .portable) return;
    var display: [260:0]u16 = [_:0]u16{0} ** 260;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Select the SysInput data directory");
    var info = api.BROWSEINFOW{
        .hwndOwner = window,
        .pidlRoot = null,
        .pszDisplayName = &display,
        .lpszTitle = title,
        .ulFlags = api.BIF_RETURNONLYFSDIRS | api.BIF_NEWDIALOGSTYLE,
        .lpfn = null,
        .lParam = 0,
        .iImage = 0,
    };
    const item = api.SHBrowseForFolderW(&info) orelse return;
    defer api.CoTaskMemFree(item);
    var wide_path: [data_location.MAX_PATH_BYTES + 1:0]u16 = [_:0]u16{0} ** (data_location.MAX_PATH_BYTES + 1);
    if (api.SHGetPathFromIDListW(item, &wide_path) == 0) return;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(&wide_path, 0)) catch {
        setStatus("The selected directory could not be read.");
        return;
    };
    defer allocator.free(utf8);
    setDirectoryText(utf8);
}

fn restoreDefaultDataDirectory() void {
    if (paths.mode == .portable) return;
    setDirectoryText(paths.defaultRoot());
    if (copy_data) |control| _ = api.SendMessageA(control, api.BM_SETCHECK, api.BST_UNCHECKED, 0);
    setStatus("Default selected. Its existing data will be used; custom data will be retained.");
}

fn applyDataDirectory() void {
    if (paths.mode == .portable) return;
    const entered = readDirectoryText() catch {
        setStatus("Enter or select a valid absolute directory.");
        return;
    };
    defer allocator.free(entered);
    const target = std.mem.trim(u8, entered, " \t\r\n");
    if (data_location.samePath(paths.root, target) and paths.location_status != .failed) {
        data_location.cancelPending(allocator, paths.control_root);
        setStatus("This directory is already in use.");
        return;
    }
    const should_copy = if (copy_data) |control| api.SendMessageA(control, api.BM_GETCHECK, 0, 0) == api.BST_CHECKED else true;
    paths.stageRootChange(target, should_copy) catch |err| {
        switch (err) {
            error.TargetDirectoryNotEmpty => setStatus("For copying, select an empty directory or clear the copy option to use existing data."),
            error.InvalidDataDirectory => setStatus("Enter or select a valid absolute directory."),
            error.TargetInsideCurrentDirectory => setStatus("Choose a directory outside the current SysInput data directory."),
            error.AccessDenied => setStatus("SysInput cannot write to that directory."),
            else => setStatus("The data-directory change could not be prepared."),
        }
        return;
    };
    setStatus("Change prepared. Exit and restart SysInput to finish the switch.");
    _ = api.MessageBoxA(window, "The data-directory change is ready. Exit SysInput normally, then start it again to copy and switch the data safely.", "SysInput", api.MB_OK | api.MB_ICONINFORMATION);
}

fn selectedApplicationIndex() ?usize {
    const list = list_box orelse return null;
    const selection = api.SendMessageA(list, api.LB_GETCURSEL, 0, 0);
    if (selection == api.LB_ERR or selection < 0) return null;
    return @intCast(selection);
}

fn addCurrentApplication() void {
    if (callbacks.add_current_application()) {
        refreshApplications();
        setStatus("Current application excluded.");
    } else setStatus("Unable to exclude the current application.");
}

fn browseApplication() void {
    var file_buffer: [exclusions.MAX_PATH_BYTES:0]u8 = [_:0]u8{0} ** exclusions.MAX_PATH_BYTES;
    var dialog = std.mem.zeroes(api.OPENFILENAMEA);
    dialog.lStructSize = @sizeOf(api.OPENFILENAMEA);
    dialog.hwndOwner = window;
    dialog.lpstrFilter = "Applications (*.exe)\x00*.exe\x00All files (*.*)\x00*.*\x00\x00";
    dialog.lpstrFile = &file_buffer;
    dialog.nMaxFile = file_buffer.len;
    dialog.lpstrTitle = "Exclude an application";
    dialog.Flags = api.OFN_FILEMUSTEXIST | api.OFN_PATHMUSTEXIST | api.OFN_NOCHANGEDIR;
    dialog.lpstrDefExt = "exe";
    if (api.GetOpenFileNameA(&dialog) == 0) return;
    _ = exclusion_store.add(std.mem.sliceTo(&file_buffer, 0)) catch {
        setStatus("The application could not be added.");
        return;
    };
    callbacks.settings_changed();
    refreshApplications();
    setStatus("Application added.");
}

fn toggleSelectedApplication() void {
    const index = selectedApplicationIndex() orelse return setStatus("Select an application first.");
    var copied: [exclusions.MAX_ENTRIES]exclusions.Entry = undefined;
    const count = exclusion_store.copyEntries(&copied);
    if (index >= count) return;
    exclusion_store.setEnabled(index, !copied[index].enabled) catch return;
    callbacks.settings_changed();
    refreshApplications();
    setStatus("Application entry updated.");
}

fn removeSelectedApplication() void {
    const index = selectedApplicationIndex() orelse return setStatus("Select an application first.");
    exclusion_store.remove(index) catch return;
    callbacks.settings_changed();
    refreshApplications();
    setStatus("Application removed.");
}

fn setStatus(text: [*:0]const u8) void {
    if (status_label) |label| _ = api.SetWindowTextA(label, text);
}

fn windowProc(hwnd: api.HWND, message: api.UINT, w_param: api.WPARAM, l_param: api.LPARAM) callconv(.C) api.LRESULT {
    switch (message) {
        api.WM_COMMAND => {
            const id: usize = w_param & 0xffff;
            const notification: usize = (w_param >> 16) & 0xffff;
            if (id == ID_NAVIGATION and notification == api.LBN_SELCHANGE) {
                const selected = api.SendMessageA(navigation.?, api.LB_GETCURSEL, 0, 0);
                if (selected >= 0 and selected < page_count) switchPage(@enumFromInt(selected));
                return 0;
            }
            if (notification == api.CBN_SELCHANGE and (id == ID_THEME or id == ID_ACCENT or id == ID_DENSITY)) {
                saveAppearance();
                return 0;
            }
            if (notification == api.BN_CLICKED) switch (id) {
                ID_ENABLED, ID_STARTUP, ID_WORD, ID_NEXT, ID_PHRASE, ID_SENTENCE, ID_LEARNING, ID_SAFE_ARROWS, ID_ABBREVIATIONS, ID_AUTO_ABBREVIATIONS, ID_CORPUS => handleCheckbox(id),
                ID_MANAGE_ABBREVIATIONS => abbreviation_window.show(),
                ID_MANAGE_CORPUS => corpus_window.show(),
                ID_SET_PREFIX => setAbbreviationPrefix(),
                ID_ADD_CURRENT => addCurrentApplication(),
                ID_BROWSE => browseApplication(),
                ID_TOGGLE_APP => toggleSelectedApplication(),
                ID_REMOVE_APP => removeSelectedApplication(),
                ID_BROWSE_DATA => browseDataDirectory(),
                ID_RESTORE_DATA => restoreDefaultDataDirectory(),
                ID_APPLY_DATA => applyDataDirectory(),
                else => {},
            };
            return 0;
        },
        api.WM_CLOSE => {
            _ = api.ShowWindow(hwnd, api.SW_HIDE);
            return 0;
        },
        api.WM_DESTROY => {
            window = null;
            navigation = null;
            page_title = null;
            status_label = null;
            list_box = null;
            abbreviation_prefix = null;
            theme_combo = null;
            accent_combo = null;
            density_combo = null;
            data_directory = null;
            copy_data = null;
            controls = [_]?api.HWND{null} ** bindings.len;
            page_control_count = 0;
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, message, w_param, l_param),
    }
}
