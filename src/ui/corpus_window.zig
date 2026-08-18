const std = @import("std");
const sysinput = @import("root").sysinput;
const api = sysinput.win32.api;
const corpus = sysinput.text.corpus;

const CLASS = "SysInputCorpusWindow";
const ID_LIST = 4100;
const ID_FILE = 4101;
const ID_FOLDER = 4102;
const ID_TOGGLE = 4103;
const ID_REBUILD = 4104;
const ID_DELETE = 4105;
const ID_CANCEL = 4106;

var instance: api.HINSTANCE = undefined;
var service: *corpus.Service = undefined;
var window: ?api.HWND = null;
var class_atom: api.ATOM = 0;
var list: ?api.HWND = null;
var status_label: ?api.HWND = null;
var visible_ids: [corpus.MAX_CORPORA]u32 = undefined;
var visible_count: usize = 0;

pub fn init(module: api.HINSTANCE, corpus_service: *corpus.Service) !void {
    instance = module;
    service = corpus_service;
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
    if (class_atom == 0) return error.CorpusWindowRegistrationFailed;
}

pub fn deinit() void {
    service.setNotifyWindow(null);
    if (window) |handle| _ = api.DestroyWindow(handle);
    window = null;
    if (class_atom != 0) _ = api.UnregisterClassA(CLASS, instance);
    class_atom = 0;
}

pub fn show() void {
    if (window == null) create() catch return;
    service.setNotifyWindow(window);
    refresh();
    _ = api.ShowWindow(window.?, api.SW_SHOW);
    _ = api.SetForegroundWindow(window.?);
}

fn control(class: [*:0]const u8, title: [*:0]const u8, style: api.DWORD, x: c_int, y: c_int, width: c_int, height: c_int, parent: api.HWND, id: usize) !api.HWND {
    const edge: api.DWORD = if (std.mem.eql(u8, std.mem.span(class), "LISTBOX")) api.WS_EX_CLIENTEDGE else 0;
    return api.CreateWindowExA(edge, class, title, api.WS_CHILD | api.WS_VISIBLE | style, x, y, width, height, parent, if (id == 0) null else @ptrFromInt(id), instance, null) orelse error.CorpusControlCreationFailed;
}

fn create() !void {
    window = api.CreateWindowExA(api.WS_EX_APPWINDOW, CLASS, "SysInput Corpus", api.WS_OVERLAPPEDWINDOW, api.CW_USEDEFAULT, api.CW_USEDEFAULT, 880, 560, null, null, instance, null) orelse return error.CorpusWindowCreationFailed;
    const parent = window.?;
    _ = try control("STATIC", "Imported UTF-8 text and Markdown sources", 0, 18, 16, 700, 22, parent, 0);
    list = try control("LISTBOX", "", api.WS_VSCROLL | api.LBS_NOTIFY | api.WS_TABSTOP, 18, 46, 826, 310, parent, ID_LIST);
    _ = try control("BUTTON", "Import file...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 18, 374, 120, 30, parent, ID_FILE);
    _ = try control("BUTTON", "Import folder...", api.BS_PUSHBUTTON | api.WS_TABSTOP, 150, 374, 130, 30, parent, ID_FOLDER);
    _ = try control("BUTTON", "Enable / disable", api.BS_PUSHBUTTON | api.WS_TABSTOP, 292, 374, 140, 30, parent, ID_TOGGLE);
    _ = try control("BUTTON", "Rebuild", api.BS_PUSHBUTTON | api.WS_TABSTOP, 444, 374, 100, 30, parent, ID_REBUILD);
    _ = try control("BUTTON", "Delete", api.BS_PUSHBUTTON | api.WS_TABSTOP, 556, 374, 100, 30, parent, ID_DELETE);
    _ = try control("BUTTON", "Cancel indexing", api.BS_PUSHBUTTON | api.WS_TABSTOP, 668, 374, 140, 30, parent, ID_CANCEL);
    status_label = try control("STATIC", "Idle", 0, 18, 424, 826, 44, parent, 0);
    _ = try control("STATIC", "Raw source files are never modified or copied. Runtime prediction reads only the compact local index.", 0, 18, 478, 826, 22, parent, 0);
}

fn refresh() void {
    const handle = list orelse return;
    _ = api.SendMessageA(handle, api.LB_RESETCONTENT, 0, 0);
    visible_count = 0;
    var metadata: [corpus.MAX_CORPORA]corpus.Metadata = undefined;
    const count = service.copyMetadata(&metadata);
    for (metadata[0..count]) |*entry| {
        visible_ids[visible_count] = entry.id;
        visible_count += 1;
        var row: [760:0]u8 = undefined;
        const rendered = std.fmt.bufPrint(row[0 .. row.len - 1], "[{s}] {s} | {s} | {d} files | {s}", .{
            if (entry.enabled) "x" else " ", entry.nameSlice(), @tagName(entry.status), entry.file_count, entry.sourceSlice(),
        }) catch continue;
        row[rendered.len] = 0;
        _ = api.SendMessageA(handle, api.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&row)));
    }
    if (status_label) |label| {
        if (service.isBusy()) {
            var text: [160:0]u8 = undefined;
            const rendered = std.fmt.bufPrint(text[0 .. text.len - 1], "Indexing in background: {d}% (typing remains active)", .{service.progressValue()}) catch return;
            text[rendered.len] = 0;
            _ = api.SetWindowTextA(label, &text);
        } else _ = api.SetWindowTextA(label, "Idle");
    }
}

fn selectedId() ?u32 {
    const handle = list orelse return null;
    const selected = api.SendMessageA(handle, api.LB_GETCURSEL, 0, 0);
    if (selected == api.LB_ERR or selected < 0 or selected >= visible_count) return null;
    return visible_ids[@intCast(selected)];
}

fn importFile() void {
    var path: [corpus.MAX_PATH_BYTES:0]u8 = [_:0]u8{0} ** corpus.MAX_PATH_BYTES;
    var dialog = std.mem.zeroes(api.OPENFILENAMEA);
    dialog.lStructSize = @sizeOf(api.OPENFILENAMEA);
    dialog.hwndOwner = window;
    dialog.lpstrFilter = "Text and Markdown (*.txt;*.md)\x00*.txt;*.md\x00\x00";
    dialog.lpstrFile = &path;
    dialog.nMaxFile = path.len;
    dialog.lpstrTitle = "Import corpus file";
    dialog.Flags = api.OFN_FILEMUSTEXIST | api.OFN_PATHMUSTEXIST | api.OFN_NOCHANGEDIR;
    if (api.GetOpenFileNameA(&dialog) == 0) return;
    service.startImport(std.mem.sliceTo(&path, 0), false) catch {
        _ = api.MessageBoxA(window, "The corpus importer is busy or the file is invalid.", "SysInput", api.MB_OK | api.MB_ICONWARNING);
    };
    refresh();
}

fn importFolder() void {
    var display: [corpus.MAX_PATH_BYTES:0]u8 = [_:0]u8{0} ** corpus.MAX_PATH_BYTES;
    var info = api.BROWSEINFOA{ .hwndOwner = window, .pidlRoot = null, .pszDisplayName = &display, .lpszTitle = "Import a folder of .txt and .md files", .ulFlags = api.BIF_RETURNONLYFSDIRS | api.BIF_NEWDIALOGSTYLE, .lpfn = null, .lParam = 0, .iImage = 0 };
    const item = api.SHBrowseForFolderA(&info) orelse return;
    defer api.CoTaskMemFree(item);
    var path: [corpus.MAX_PATH_BYTES:0]u8 = [_:0]u8{0} ** corpus.MAX_PATH_BYTES;
    if (api.SHGetPathFromIDListA(item, &path) == 0) return;
    service.startImport(std.mem.sliceTo(&path, 0), true) catch {
        _ = api.MessageBoxA(window, "The corpus importer is busy or the folder is invalid.", "SysInput", api.MB_OK | api.MB_ICONWARNING);
    };
    refresh();
}

fn startSelected(operation: enum { toggle, rebuild, remove }) void {
    const id = selectedId() orelse return;
    switch (operation) {
        .toggle => service.startToggle(id) catch {},
        .rebuild => service.startRebuild(id) catch {},
        .remove => service.startRemove(id) catch {},
    }
    refresh();
}

fn proc(hwnd: api.HWND, message: api.UINT, w: api.WPARAM, l: api.LPARAM) callconv(.C) api.LRESULT {
    switch (message) {
        api.WM_COMMAND => {
            if (((w >> 16) & 0xffff) == api.BN_CLICKED) switch (w & 0xffff) {
                ID_FILE => importFile(),
                ID_FOLDER => importFolder(),
                ID_TOGGLE => startSelected(.toggle),
                ID_REBUILD => startSelected(.rebuild),
                ID_DELETE => startSelected(.remove),
                ID_CANCEL => service.requestCancel(),
                else => {},
            };
            return 0;
        },
        corpus.WM_CORPUS_CHANGED => {
            refresh();
            return 0;
        },
        api.WM_CLOSE => {
            _ = api.ShowWindow(hwnd, api.SW_HIDE);
            return 0;
        },
        api.WM_DESTROY => {
            service.setNotifyWindow(null);
            window = null;
            list = null;
            status_label = null;
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, message, w, l),
    }
}
