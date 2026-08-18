const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const runtime_settings = sysinput.core.runtime_settings;
const exclusions = sysinput.core.application_exclusions;
const abbreviation_window = sysinput.ui.abbreviation_window;
const corpus_window = sysinput.ui.corpus_window;
const appearance_window = sysinput.ui.appearance_window;

const WINDOW_CLASS = "SysInputSettingsWindow";
const WINDOW_TITLE = "SysInput Settings";
const APP_ICON_ID = 101;

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
const ID_APPEARANCE = 2035;

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

var allocator: std.mem.Allocator = undefined;
var instance: api.HINSTANCE = undefined;
var settings: *runtime_settings.Store = undefined;
var exclusion_store: *exclusions.Store = undefined;
var callbacks: Callbacks = undefined;
var window: ?api.HWND = null;
var window_class: api.ATOM = 0;
var list_box: ?api.HWND = null;
var status_label: ?api.HWND = null;
var abbreviation_prefix: ?api.HWND = null;
var controls: [bindings.len]?api.HWND = [_]?api.HWND{null} ** bindings.len;
var settings_font: ?api.HFONT = null;

pub fn init(
    ui_allocator: std.mem.Allocator,
    module_instance: api.HINSTANCE,
    runtime_store: *runtime_settings.Store,
    applications: *exclusions.Store,
    ui_callbacks: Callbacks,
) !void {
    allocator = ui_allocator;
    instance = module_instance;
    settings = runtime_store;
    exclusion_store = applications;
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
    if (window) |handle| {
        _ = api.DestroyWindow(handle);
        window = null;
    }
    if (window_class != 0) {
        _ = api.UnregisterClassA(WINDOW_CLASS, instance);
        window_class = 0;
    }
    if (settings_font) |font| {
        _ = api.DeleteObject(font);
        settings_font = null;
    }
}

pub fn show() void {
    if (window == null) createWindow() catch return;
    refresh();
    _ = api.ShowWindow(window.?, api.SW_SHOW);
    _ = api.SetForegroundWindow(window.?);
    _ = api.UpdateWindow(window.?);
}

pub fn refresh() void {
    refreshSettings();
    refreshApplications();
}

pub fn refreshApplications() void {
    const list = list_box orelse return;
    _ = api.SendMessageA(list, api.LB_RESETCONTENT, 0, 0);
    var copied: [exclusions.MAX_ENTRIES]exclusions.Entry = undefined;
    const count = exclusion_store.copyEntries(&copied);
    for (copied[0..count]) |*entry| {
        var row: [exclusions.MAX_PATH_BYTES + 8:0]u8 = undefined;
        const formatted = std.fmt.bufPrint(row[0 .. row.len - 1], "[{s}] {s}", .{
            if (entry.enabled) "x" else " ",
            entry.pathSlice(),
        }) catch continue;
        row[formatted.len] = 0;
        _ = api.SendMessageA(list, api.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&row)));
    }
}

fn createWindow() !void {
    window = api.CreateWindowExA(
        api.WS_EX_APPWINDOW,
        WINDOW_CLASS,
        WINDOW_TITLE,
        api.WS_OVERLAPPEDWINDOW,
        api.CW_USEDEFAULT,
        api.CW_USEDEFAULT,
        760,
        620,
        null,
        null,
        instance,
        null,
    ) orelse return error.SettingsWindowCreationFailed;
    try createControls(window.?);
}

fn createControls(parent: api.HWND) !void {
    _ = try createControl("BUTTON", "General", api.BS_GROUPBOX, 16, 12, 350, 110, parent, 0);
    controls[0] = try createControl("BUTTON", "Predictions enabled", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 32, 40, 260, 24, parent, ID_ENABLED);
    controls[1] = try createControl("BUTTON", "Start with Windows", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 32, 72, 260, 24, parent, ID_STARTUP);

    _ = try createControl("BUTTON", "Prediction", api.BS_GROUPBOX, 382, 12, 346, 210, parent, 0);
    controls[2] = try createControl("BUTTON", "Word completion", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 398, 40, 290, 24, parent, ID_WORD);
    controls[3] = try createControl("BUTTON", "Next-word prediction", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 398, 72, 290, 24, parent, ID_NEXT);
    controls[4] = try createControl("BUTTON", "Phrase completion", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 398, 104, 290, 24, parent, ID_PHRASE);
    controls[5] = try createControl("BUTTON", "Sentence prediction", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 398, 136, 290, 24, parent, ID_SENTENCE);
    controls[6] = try createControl("BUTTON", "Personal learning", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 398, 168, 290, 24, parent, ID_LEARNING);

    _ = try createControl("BUTTON", "Keyboard", api.BS_GROUPBOX, 16, 132, 350, 90, parent, 0);
    controls[7] = try createControl("BUTTON", "Safe arrow mode (recommended)", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 32, 162, 300, 24, parent, ID_SAFE_ARROWS);
    _ = try createControl("BUTTON", "Candidate appearance...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 32, 190, 180, 26, parent, ID_APPEARANCE);

    _ = try createControl("BUTTON", "Abbreviations", api.BS_GROUPBOX, 16, 232, 350, 66, parent, 0);
    controls[8] = try createControl("BUTTON", "Enable abbreviation expansion", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 32, 254, 220, 24, parent, ID_ABBREVIATIONS);
    _ = try createControl("BUTTON", "Manage...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 258, 252, 88, 26, parent, ID_MANAGE_ABBREVIATIONS);
    controls[9] = try createControl("BUTTON", "Auto with prefix", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 32, 278, 126, 18, parent, ID_AUTO_ABBREVIATIONS);
    abbreviation_prefix = try createControl("EDIT", ";", api.ES_AUTOHSCROLL | api.WS_TABSTOP, 164, 276, 30, 22, parent, ID_ABBREVIATION_PREFIX);
    _ = try createControl("BUTTON", "Set", api.BS_PUSHBUTTON | api.WS_TABSTOP, 200, 276, 46, 22, parent, ID_SET_PREFIX);
    _ = try createControl("BUTTON", "Corpus", api.BS_GROUPBOX, 382, 232, 346, 66, parent, 0);
    controls[10] = try createControl("BUTTON", "Enable corpus prediction", api.BS_AUTOCHECKBOX | api.WS_TABSTOP, 398, 254, 200, 24, parent, ID_CORPUS);
    _ = try createControl("BUTTON", "Manage...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 620, 252, 88, 26, parent, ID_MANAGE_CORPUS);

    _ = try createControl("BUTTON", "Applications", api.BS_GROUPBOX, 16, 310, 712, 190, parent, 0);
    list_box = try createControl("LISTBOX", "", api.WS_VSCROLL | api.LBS_NOTIFY | api.WS_TABSTOP, 32, 338, 680, 100, parent, ID_APP_LIST);
    _ = try createControl("BUTTON", "Add current", api.BS_PUSHBUTTON | api.WS_TABSTOP, 32, 452, 120, 28, parent, ID_ADD_CURRENT);
    _ = try createControl("BUTTON", "Browse...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 164, 452, 100, 28, parent, ID_BROWSE);
    _ = try createControl("BUTTON", "Enable / disable", api.BS_PUSHBUTTON | api.WS_TABSTOP, 276, 452, 140, 28, parent, ID_TOGGLE_APP);
    _ = try createControl("BUTTON", "Remove", api.BS_PUSHBUTTON | api.WS_TABSTOP, 428, 452, 100, 28, parent, ID_REMOVE_APP);

    _ = try createControl("BUTTON", "Data", api.BS_GROUPBOX, 16, 510, 480, 55, parent, 0);
    var data_text: [exclusions.MAX_PATH_BYTES + 16:0]u8 = undefined;
    const data_directory = std.fs.path.dirname(settings.path) orelse settings.path;
    const data_line = try std.fmt.bufPrint(data_text[0 .. data_text.len - 1], "Data: {s}", .{data_directory});
    data_text[data_line.len] = 0;
    _ = try createControl("STATIC", &data_text, 0, 32, 532, 448, 20, parent, 0);
    _ = try createControl("BUTTON", "About", api.BS_GROUPBOX, 510, 510, 218, 55, parent, 0);
    _ = try createControl("STATIC", "SysInput v0.2 beta", 0, 526, 532, 186, 20, parent, 0);
    status_label = try createControl("STATIC", "", 0, 32, 570, 680, 20, parent, 0);
    refresh();
}

fn createControl(
    class_name: [*:0]const u8,
    title: [*:0]const u8,
    control_style: api.DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: api.HWND,
    id: usize,
) !api.HWND {
    const handle = api.CreateWindowExA(
        if (std.mem.eql(u8, std.mem.span(class_name), "LISTBOX")) api.WS_EX_CLIENTEDGE else 0,
        class_name,
        title,
        api.WS_CHILD | api.WS_VISIBLE | control_style,
        x,
        y,
        width,
        height,
        parent,
        if (id == 0) null else @ptrFromInt(id),
        instance,
        null,
    ) orelse return error.SettingsControlCreationFailed;
    if (settings_font) |font| _ = api.SendMessageA(handle, api.WM_SETFONT, @intFromPtr(font), 1);
    return handle;
}

fn refreshSettings() void {
    for (bindings, 0..) |binding, index| {
        const control = controls[index] orelse continue;
        _ = api.SendMessageA(control, api.BM_SETCHECK, if (settings.isEnabled(binding.feature)) api.BST_CHECKED else api.BST_UNCHECKED, 0);
    }
    if (abbreviation_prefix) |control| {
        var text: [2:0]u8 = .{ settings.snapshot().abbreviation_prefix, 0 };
        _ = api.SetWindowTextA(control, &text);
    }
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

fn selectedApplicationIndex() ?usize {
    const list = list_box orelse return null;
    const selection = api.SendMessageA(list, api.LB_GETCURSEL, 0, 0);
    if (selection == api.LB_ERR or selection < 0) return null;
    return @intCast(selection);
}

fn addCurrentApplication() void {
    if (callbacks.add_current_application()) {
        setStatus("Current application excluded.");
        refreshApplications();
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
    const selected = std.mem.sliceTo(&file_buffer, 0);
    _ = exclusion_store.add(selected) catch {
        setStatus("The application could not be added.");
        return;
    };
    callbacks.settings_changed();
    refreshApplications();
    setStatus("Application added.");
}

fn toggleSelectedApplication() void {
    const index = selectedApplicationIndex() orelse {
        setStatus("Select an application first.");
        return;
    };
    var copied: [exclusions.MAX_ENTRIES]exclusions.Entry = undefined;
    const count = exclusion_store.copyEntries(&copied);
    if (index >= count) return;
    exclusion_store.setEnabled(index, !copied[index].enabled) catch return;
    callbacks.settings_changed();
    refreshApplications();
    setStatus("Application entry updated.");
}

fn removeSelectedApplication() void {
    const index = selectedApplicationIndex() orelse {
        setStatus("Select an application first.");
        return;
    };
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
            if (notification == api.BN_CLICKED) {
                switch (id) {
                    ID_ENABLED, ID_STARTUP, ID_WORD, ID_NEXT, ID_PHRASE, ID_SENTENCE, ID_LEARNING, ID_SAFE_ARROWS, ID_ABBREVIATIONS, ID_AUTO_ABBREVIATIONS, ID_CORPUS => handleCheckbox(id),
                    ID_MANAGE_ABBREVIATIONS => abbreviation_window.show(),
                    ID_MANAGE_CORPUS => corpus_window.show(),
                    ID_APPEARANCE => appearance_window.show(),
                    ID_SET_PREFIX => setAbbreviationPrefix(),
                    ID_ADD_CURRENT => addCurrentApplication(),
                    ID_BROWSE => browseApplication(),
                    ID_TOGGLE_APP => toggleSelectedApplication(),
                    ID_REMOVE_APP => removeSelectedApplication(),
                    else => {},
                }
            }
            return 0;
        },
        api.WM_CLOSE => {
            _ = api.ShowWindow(hwnd, api.SW_HIDE);
            return 0;
        },
        api.WM_DESTROY => {
            window = null;
            list_box = null;
            status_label = null;
            abbreviation_prefix = null;
            controls = [_]?api.HWND{null} ** bindings.len;
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, message, w_param, l_param),
    }
}
