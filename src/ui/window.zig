const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const debug = sysinput.core.debug;
const config = sysinput.core.config;
const runtime_settings = sysinput.core.runtime_settings;
const appearance = sysinput.ui.appearance;
const position = sysinput.ui.position;

pub const SUGGESTION_WINDOW_CLASS = "SysInputSuggestions";
pub const WINDOW_PADDING = 2;

pub const UiState = struct {
    suggestions: [][]const u8 = &[_][]const u8{},
    selected_index: i32 = -1,
    font: ?api.HFONT = null,
    appearance_value: runtime_settings.Appearance = .{},
    palette: appearance.Palette = appearance.paletteFor(false, appearance.rgb(0, 120, 212)),
    metrics: appearance.Metrics = appearance.metricsFor(.compact),
    appearance_revision: u32 = 1,
    font_revision: u32 = 0,
};

pub var g_ui_state = UiState{};

pub const SuggestionClickCallback = *const fn (usize) void;
var g_click_callback: ?SuggestionClickCallback = null;

pub fn setSuggestionClickCallback(callback: ?SuggestionClickCallback) void {
    g_click_callback = callback;
}

pub fn setAppearance(value: runtime_settings.Appearance) void {
    g_ui_state.appearance_value = value;
    g_ui_state.palette = appearance.resolvePalette(value);
    g_ui_state.metrics = appearance.metricsFor(value.density);
    g_ui_state.appearance_revision +%= 1;
}

pub fn currentMetrics() appearance.Metrics {
    return g_ui_state.metrics;
}

fn applyNativeFrame(hwnd: api.HWND) void {
    var preference: api.DWORD = api.DWMWCP_ROUND;
    _ = api.DwmSetWindowAttribute(hwnd, api.DWMWA_WINDOW_CORNER_PREFERENCE, &preference, @sizeOf(api.DWORD));
    var border = g_ui_state.palette.border;
    _ = api.DwmSetWindowAttribute(hwnd, api.DWMWA_BORDER_COLOR, &border, @sizeOf(api.COLORREF));
}

pub fn refreshWindowAppearance(hwnd: api.HWND) void {
    applyNativeFrame(hwnd);
    ensureFont(hwnd);
    _ = api.InvalidateRect(hwnd, null, 0);
}

fn ensureFont(hwnd: api.HWND) void {
    if (g_ui_state.font != null and g_ui_state.font_revision == g_ui_state.appearance_revision) return;
    if (g_ui_state.font) |font| {
        _ = api.DeleteObject(font);
        g_ui_state.font = null;
    }
    const scale = position.dpiScaleForWindow(hwnd);
    g_ui_state.font = api.CreateFontA(
        -position.scaleValue(g_ui_state.metrics.font_height, scale),
        0,
        0,
        0,
        config.WIN32.FONT_WEIGHT_NORMAL,
        0,
        0,
        0,
        config.WIN32.FONT_CHARSET,
        api.OUT_DEFAULT_PRECIS,
        api.CLIP_DEFAULT_PRECIS,
        config.WIN32.FONT_QUALITY,
        api.DEFAULT_PITCH | api.FF_DONTCARE,
        config.UI.FONT_FACE,
    );
    g_ui_state.font_revision = g_ui_state.appearance_revision;
}

fn fill(hdc: api.HDC, rect: *const api.RECT, color: api.COLORREF) void {
    const brush = api.CreateSolidBrush(color) orelse return;
    defer _ = api.DeleteObject(brush);
    _ = api.FillRect(hdc, rect, brush);
}

fn drawRoundedSelection(hdc: api.HDC, rect: api.RECT, radius: i32, color: api.COLORREF) void {
    const brush = api.CreateSolidBrush(color) orelse return;
    defer _ = api.DeleteObject(brush);
    const old_brush = api.SelectObject(hdc, brush);
    const null_pen = api.GetStockObject(api.NULL_PEN) orelse return;
    const old_pen = api.SelectObject(hdc, null_pen);
    _ = api.RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
    if (old_pen) |object| _ = api.SelectObject(hdc, object);
    if (old_brush) |object| _ = api.SelectObject(hdc, object);
}

fn drawContent(hwnd: api.HWND, hdc: api.HDC, client: api.RECT) void {
    const palette = g_ui_state.palette;
    const scale = position.dpiScaleForWindow(hwnd);
    const outer = position.scaleValue(g_ui_state.metrics.outer_padding, scale);
    const row_height = position.scaleValue(g_ui_state.metrics.row_height, scale);
    const horizontal = position.scaleValue(g_ui_state.metrics.horizontal_padding, scale);
    const radius = position.scaleValue(g_ui_state.metrics.corner_radius, scale);
    const accent_width = position.scaleValue(3, scale);

    fill(hdc, &client, palette.surface);
    if (g_ui_state.font) |font| _ = api.SelectObject(hdc, font);
    _ = api.SetBkMode(hdc, api.TRANSPARENT);

    for (g_ui_state.suggestions, 0..) |suggestion, index| {
        const top = outer + @as(i32, @intCast(index)) * row_height;
        const selected = g_ui_state.selected_index == @as(i32, @intCast(index));
        var row = api.RECT{
            .left = outer,
            .top = top,
            .right = client.right - outer,
            .bottom = top + row_height,
        };
        if (selected) {
            drawRoundedSelection(hdc, row, radius, palette.selected_surface);
            const accent = api.RECT{
                .left = row.left,
                .top = row.top + position.scaleValue(6, scale),
                .right = row.left + accent_width,
                .bottom = row.bottom - position.scaleValue(6, scale),
            };
            fill(hdc, &accent, palette.accent);
            _ = api.SetTextColor(hdc, palette.selected_text);
        } else {
            _ = api.SetTextColor(hdc, palette.text);
        }

        var buffer: [config.TEXT.MAX_SUGGESTION_LEN:0]u8 = undefined;
        const length = @min(suggestion.len, config.TEXT.MAX_SUGGESTION_LEN);
        @memcpy(buffer[0..length], suggestion[0..length]);
        buffer[length] = 0;
        row.left += horizontal;
        row.right -= horizontal;
        _ = api.DrawTextA(hdc, &buffer, @intCast(length), &row, api.DT_LEFT | api.DT_SINGLELINE | api.DT_VCENTER | api.DT_END_ELLIPSIS);
    }

    // A one-pixel neutral border keeps the popup legible when DWM does not
    // support rounded-corner attributes (for example, older Windows builds).
    const one = position.scaleValue(1, scale);
    fill(hdc, &api.RECT{ .left = 0, .top = 0, .right = client.right, .bottom = one }, palette.border);
    fill(hdc, &api.RECT{ .left = 0, .top = client.bottom - one, .right = client.right, .bottom = client.bottom }, palette.border);
    fill(hdc, &api.RECT{ .left = 0, .top = 0, .right = one, .bottom = client.bottom }, palette.border);
    fill(hdc, &api.RECT{ .left = client.right - one, .top = 0, .right = client.right, .bottom = client.bottom }, palette.border);
}

fn paint(hwnd: api.HWND, target: api.HDC) void {
    var client: api.RECT = undefined;
    if (api.GetClientRect(hwnd, &client) == 0) return;
    ensureFont(hwnd);
    const width = client.right - client.left;
    const height = client.bottom - client.top;
    const memory = api.CreateCompatibleDC(target) orelse {
        drawContent(hwnd, target, client);
        return;
    };
    defer _ = api.DeleteDC(memory);
    const bitmap = api.CreateCompatibleBitmap(target, width, height) orelse {
        drawContent(hwnd, target, client);
        return;
    };
    defer _ = api.DeleteObject(bitmap);
    const old_bitmap = api.SelectObject(memory, bitmap);
    drawContent(hwnd, memory, client);
    _ = api.BitBlt(target, 0, 0, width, height, memory, 0, 0, api.SRCCOPY);
    if (old_bitmap) |object| _ = api.SelectObject(memory, object);
}

pub fn suggestionWindowProc(hwnd: api.HWND, msg: api.UINT, wParam: api.WPARAM, lParam: api.LPARAM) callconv(.C) api.LRESULT {
    switch (msg) {
        api.WM_CREATE => {
            if (g_ui_state.appearance_value.theme == .system or g_ui_state.appearance_value.accent == .system) {
                setAppearance(g_ui_state.appearance_value);
            }
            applyNativeFrame(hwnd);
            ensureFont(hwnd);
            return 0;
        },
        api.WM_PAINT => {
            var ps: api.PAINTSTRUCT = undefined;
            const hdc = api.BeginPaint(hwnd, &ps);
            defer _ = api.EndPaint(hwnd, &ps);
            paint(hwnd, hdc);
            return 0;
        },
        api.WM_LBUTTONDOWN => {
            const y: i32 = @as(i16, @truncate((lParam >> 16) & 0xffff));
            const scale = position.dpiScaleForWindow(hwnd);
            const outer = position.scaleValue(g_ui_state.metrics.outer_padding, scale);
            const row_height = position.scaleValue(g_ui_state.metrics.row_height, scale);
            const index = @divTrunc(y - outer, row_height);
            if (index >= 0 and index < g_ui_state.suggestions.len) {
                g_ui_state.selected_index = @intCast(index);
                _ = api.InvalidateRect(hwnd, null, 0);
                if (g_click_callback) |callback| callback(@intCast(index));
            }
            return 0;
        },
        api.WM_SETTINGCHANGE => {
            if (g_ui_state.appearance_value.theme == .system or g_ui_state.appearance_value.accent == .system) {
                setAppearance(g_ui_state.appearance_value);
                applyNativeFrame(hwnd);
                _ = api.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        api.WM_ERASEBKGND => return 1,
        api.WM_DESTROY => {
            if (g_ui_state.font) |font| {
                _ = api.DeleteObject(font);
                g_ui_state.font = null;
            }
            return 0;
        },
        else => return api.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

pub fn registerSuggestionWindowClass(instance: api.HINSTANCE) !api.ATOM {
    const wc = api.WNDCLASSEX{
        .cbSize = @sizeOf(api.WNDCLASSEX),
        .style = config.WIN32.SUGGESTION_CLASS_STYLE,
        .lpfnWndProc = suggestionWindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = api.LoadCursorA(null, api.makeIntResource(api.IDC_ARROW)),
        .hbrBackground = @ptrCast(api.GetStockObject(api.NULL_BRUSH).?),
        .lpszMenuName = null,
        .lpszClassName = SUGGESTION_WINDOW_CLASS,
        .hIconSm = null,
    };
    const atom = api.RegisterClassExA(&wc);
    if (atom == 0) {
        debug.debugPrint("Failed to register suggestion window class\n", .{});
        return error.WindowClassRegistrationFailed;
    }
    return atom;
}
