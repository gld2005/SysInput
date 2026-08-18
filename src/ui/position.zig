const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const debug = sysinput.core.debug;
const config = sysinput.core.config;

pub const PopupSize = struct { width: i32, height: i32 };
pub const PopupPlacement = struct { x: i32, y: i32, width: i32, height: i32 };

const PositionCache = struct {
    caret: api.RECT = std.mem.zeroes(api.RECT),
    timestamp: i64 = 0,
    window_handle: ?api.HWND = null,
    valid: bool = false,

    fn isValid(self: *const PositionCache, current_hwnd: ?api.HWND) bool {
        if (!config.PERFORMANCE.USE_POSITION_CACHE or !self.valid) return false;
        if (self.window_handle != current_hwnd) return false;
        return std.time.milliTimestamp() - self.timestamp < config.PERFORMANCE.POSITION_CACHE_LIFETIME_MS;
    }

    fn update(self: *PositionCache, caret: api.RECT, hwnd: ?api.HWND) void {
        self.caret = caret;
        self.timestamp = std.time.milliTimestamp();
        self.window_handle = hwnd;
        self.valid = true;
    }

    fn invalidate(self: *PositionCache) void {
        self.valid = false;
    }
};

var position_cache = PositionCache{};

fn getDpiScaling(hwnd: ?api.HWND) f32 {
    if (hwnd) |window| {
        const dpi = api.GetDpiForWindow(window);
        if (dpi != 0) return @as(f32, @floatFromInt(dpi)) / config.UI.BASE_DPI;
    }
    const hdc = api.GetDC(null) orelse return 1.0;
    defer _ = api.ReleaseDC(null, hdc);
    return @as(f32, @floatFromInt(api.GetDeviceCaps(hdc, api.LOGPIXELSY))) / config.UI.BASE_DPI;
}

fn scaled(value: i32, scale: f32) i32 {
    return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(value)) * scale)));
}

fn normalizeCaretRect(rect: api.RECT, focus: ?api.HWND) api.RECT {
    var result = rect;
    if (result.right <= result.left) result.right = result.left + 1;
    if (result.bottom <= result.top) result.bottom = result.top + scaled(config.UI.SUGGESTION_FONT_HEIGHT, getDpiScaling(focus));
    return result;
}

fn clientRectToScreen(window: api.HWND, rect: api.RECT) api.RECT {
    var top_left = api.POINT{ .x = rect.left, .y = rect.top };
    var bottom_right = api.POINT{ .x = rect.right, .y = rect.bottom };
    _ = api.ClientToScreen(window, &top_left);
    _ = api.ClientToScreen(window, &bottom_right);
    return .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y };
}

fn isEditControl(window: api.HWND) bool {
    var class_name: [64:0]u8 = [_:0]u8{0} ** 64;
    const length = api.GetClassNameA(window, &class_name, @intCast(class_name.len));
    if (length <= 0) return false;
    const name = class_name[0..@intCast(length)];
    return std.mem.eql(u8, name, "Edit") or std.mem.startsWith(u8, name, "RichEdit");
}

fn attachedCaretRect(focus: api.HWND, target_thread: api.DWORD) ?api.RECT {
    const current_thread = api.GetCurrentThreadId();
    const needs_attach = current_thread != target_thread;
    if (needs_attach and api.AttachThreadInput(current_thread, target_thread, 1) == 0) return null;
    defer {
        if (needs_attach) _ = api.AttachThreadInput(current_thread, target_thread, 0);
    }

    var point = api.POINT{ .x = 0, .y = 0 };
    if (api.GetCaretPos(&point) == 0 or api.ClientToScreen(focus, &point) == 0) return null;
    const height = scaled(config.UI.SUGGESTION_FONT_HEIGHT, getDpiScaling(focus));
    return .{ .left = point.x, .top = point.y, .right = point.x + 1, .bottom = point.y + height };
}

/// Returns a screen-space caret rectangle. A missing reliable anchor is
/// reported as null instead of placing the popup at the mouse cursor.
pub fn getCaretRect() ?api.RECT {
    const focus = api.getFocusedWindow() orelse return null;
    if (position_cache.isValid(focus)) return position_cache.caret;

    const thread_id = api.GetWindowThreadProcessId(focus, null);
    var info = std.mem.zeroes(api.GUITHREADINFO);
    info.cbSize = @sizeOf(api.GUITHREADINFO);
    if (thread_id != 0 and api.GetGUIThreadInfo(thread_id, &info) != 0 and info.hwndCaret != null) {
        const caret = normalizeCaretRect(clientRectToScreen(info.hwndCaret.?, info.rcCaret), focus);
        position_cache.update(caret, focus);
        debug.debugPrint("Caret rect from GUITHREADINFO: {d},{d}-{d},{d}\n", .{ caret.left, caret.top, caret.right, caret.bottom });
        return caret;
    }

    // Some applications expose a system caret only after the input queues are
    // attached. This remains on the UI path and never runs in the hook.
    if (thread_id != 0) {
        if (attachedCaretRect(focus, thread_id)) |caret| {
            position_cache.update(caret, focus);
            return caret;
        }
    }

    // EM_POSFROMCHAR is meaningful only for Win32 Edit/RichEdit controls.
    if (!isEditControl(focus)) return null;
    const selection = api.SendMessageA(focus, api.EM_GETSEL, 0, 0);
    const selection_bits: u64 = @bitCast(selection);
    const selection_end: u32 = @truncate((selection_bits >> 16) & 0xffff);
    const character_position = api.SendMessageA(focus, api.EM_POSFROMCHAR, selection_end, 0);
    if (character_position == -1) return null;
    const position_bits: usize = @bitCast(character_position);
    var screen_point = api.POINT{
        .x = @as(i16, @bitCast(@as(u16, @truncate(position_bits & 0xffff)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate((position_bits >> 16) & 0xffff)))),
    };
    if (api.ClientToScreen(focus, &screen_point) == 0) return null;
    const height = scaled(config.UI.SUGGESTION_FONT_HEIGHT, getDpiScaling(focus));
    const caret = api.RECT{
        .left = screen_point.x,
        .top = screen_point.y,
        .right = screen_point.x + 1,
        .bottom = screen_point.y + height,
    };
    position_cache.update(caret, focus);
    return caret;
}

pub fn getCaretPosition() api.POINT {
    const caret = getCaretRect() orelse return .{ .x = 0, .y = 0 };
    return .{ .x = caret.left, .y = caret.bottom };
}

pub fn getCaretAnchor() ?api.POINT {
    const caret = getCaretRect() orelse return null;
    return .{ .x = caret.left, .y = caret.bottom };
}

pub fn calculatePopupPlacement(caret: api.RECT, work_area: api.RECT, requested: PopupSize, gap: i32, edge_padding: i32) ?PopupPlacement {
    const available_width = work_area.right - work_area.left - edge_padding * 2;
    if (available_width <= 0 or requested.height <= 0) return null;
    const width = @min(requested.width, available_width);
    const height = requested.height;
    const minimum_x = work_area.left + edge_padding;
    const maximum_x = work_area.right - edge_padding - width;
    const x = std.math.clamp(caret.left, minimum_x, maximum_x);

    const below = caret.bottom + gap;
    const above = caret.top - gap - height;
    if (below + height <= work_area.bottom - edge_padding) {
        return .{ .x = x, .y = below, .width = width, .height = height };
    }
    if (above >= work_area.top + edge_padding) {
        return .{ .x = x, .y = above, .width = width, .height = height };
    }
    // Never overlap the active input line merely to force a popup onscreen.
    return null;
}

fn monitorWorkArea(caret: api.RECT) ?api.RECT {
    const monitor = api.MonitorFromRect(&caret, api.MONITOR_DEFAULTTONEAREST) orelse return null;
    var info = std.mem.zeroes(api.MONITORINFO);
    info.cbSize = @sizeOf(api.MONITORINFO);
    if (api.GetMonitorInfoA(monitor, &info) == 0) return null;
    return info.rcWork;
}

pub fn placeSuggestionPopup(caret: api.RECT, requested: PopupSize) ?PopupPlacement {
    const dpi_scale = getDpiScaling(api.getFocusedWindow());
    const work_area = monitorWorkArea(caret) orelse return null;
    return calculatePopupPlacement(caret, work_area, requested, scaled(6, dpi_scale), scaled(config.UI.SCREEN_EDGE_PADDING, dpi_scale));
}

pub fn invalidatePositionCache() void {
    position_cache.invalidate();
}

pub fn calculateSuggestionWindowSize(suggestions: [][]const u8, font_height: i32, padding: i32) PopupSize {
    const dpi_scale = getDpiScaling(api.getFocusedWindow());
    const scaled_font_height = scaled(font_height, dpi_scale);
    const scaled_padding = scaled(padding, dpi_scale);
    const line_height = scaled_font_height + scaled(4, dpi_scale);
    const window_height = @as(i32, @intCast(suggestions.len)) * line_height + scaled_padding * 2;

    var max_width: i32 = scaled(config.UI.DEFAULT_POPUP_WIDTH / 2, dpi_scale);
    const average_character_width = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(scaled_font_height)) * config.UI.AVG_CHAR_WIDTH_RATIO)));
    for (suggestions) |suggestion| {
        const width = @as(i32, @intCast(suggestion.len)) * average_character_width + scaled_padding * 4;
        max_width = @max(max_width, width);
    }
    return .{ .width = max_width, .height = window_height };
}
