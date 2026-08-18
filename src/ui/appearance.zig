const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const runtime_settings = sysinput.core.runtime_settings;

const PERSONALIZE_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
const APPS_USE_LIGHT_THEME = "AppsUseLightTheme";

pub const Palette = struct {
    surface: api.COLORREF,
    border: api.COLORREF,
    text: api.COLORREF,
    secondary_text: api.COLORREF,
    selected_surface: api.COLORREF,
    selected_text: api.COLORREF,
    accent: api.COLORREF,
    high_contrast: bool = false,
    dark: bool = false,
};

pub const Metrics = struct {
    font_height: i32,
    row_height: i32,
    horizontal_padding: i32,
    outer_padding: i32,
    corner_radius: i32,
};

pub fn rgb(red: u8, green: u8, blue: u8) api.COLORREF {
    return @as(api.COLORREF, red) | (@as(api.COLORREF, green) << 8) | (@as(api.COLORREF, blue) << 16);
}

fn systemHighContrast() bool {
    var value = std.mem.zeroes(api.HIGHCONTRASTA);
    value.cbSize = @sizeOf(api.HIGHCONTRASTA);
    if (api.SystemParametersInfoA(api.SPI_GETHIGHCONTRAST, value.cbSize, &value, 0) == 0) return false;
    return value.dwFlags & api.HCF_HIGHCONTRASTON != 0;
}

fn systemDarkMode() bool {
    var key: api.HKEY = undefined;
    if (api.RegOpenKeyExA(api.HKEY_CURRENT_USER, PERSONALIZE_KEY, 0, api.KEY_QUERY_VALUE, &key) == api.ERROR_SUCCESS) {
        defer _ = api.RegCloseKey(key);
        var value: u32 = 1;
        var value_type: api.DWORD = 0;
        var size: api.DWORD = @sizeOf(u32);
        if (api.RegQueryValueExA(key, APPS_USE_LIGHT_THEME, null, &value_type, @ptrCast(&value), &size) == api.ERROR_SUCCESS and size == @sizeOf(u32)) {
            return value == 0;
        }
    }
    const window_color = api.GetSysColor(api.COLOR_WINDOW);
    const red = window_color & 0xff;
    const green = (window_color >> 8) & 0xff;
    const blue = (window_color >> 16) & 0xff;
    return red * 299 + green * 587 + blue * 114 < 128_000;
}

fn systemAccent() api.COLORREF {
    var color: api.DWORD = 0;
    var opaque_blend: api.BOOL = 0;
    if (api.DwmGetColorizationColor(&color, &opaque_blend) >= 0) {
        return rgb(@truncate(color >> 16), @truncate(color >> 8), @truncate(color));
    }
    return api.GetSysColor(api.COLOR_HIGHLIGHT);
}

pub fn accentColor(choice: runtime_settings.Accent, system_color: api.COLORREF) api.COLORREF {
    return switch (choice) {
        .system => system_color,
        .blue => rgb(0, 120, 212),
        .teal => rgb(0, 153, 153),
        .purple => rgb(134, 97, 197),
    };
}

pub fn paletteFor(dark: bool, accent: api.COLORREF) Palette {
    if (dark) return .{
        .surface = rgb(32, 32, 32),
        .border = rgb(63, 63, 63),
        .text = rgb(245, 245, 245),
        .secondary_text = rgb(185, 185, 185),
        .selected_surface = rgb(52, 52, 52),
        .selected_text = rgb(255, 255, 255),
        .accent = accent,
        .dark = true,
    };
    return .{
        .surface = rgb(249, 249, 249),
        .border = rgb(218, 218, 218),
        .text = rgb(31, 31, 31),
        .secondary_text = rgb(96, 96, 96),
        .selected_surface = rgb(235, 243, 252),
        .selected_text = rgb(20, 20, 20),
        .accent = accent,
    };
}

pub fn resolvePalette(value: runtime_settings.Appearance) Palette {
    if (systemHighContrast()) return .{
        .surface = api.GetSysColor(api.COLOR_WINDOW),
        .border = api.GetSysColor(api.COLOR_WINDOWTEXT),
        .text = api.GetSysColor(api.COLOR_WINDOWTEXT),
        .secondary_text = api.GetSysColor(api.COLOR_WINDOWTEXT),
        .selected_surface = api.GetSysColor(api.COLOR_HIGHLIGHT),
        .selected_text = api.GetSysColor(api.COLOR_HIGHLIGHTTEXT),
        .accent = api.GetSysColor(api.COLOR_HIGHLIGHT),
        .high_contrast = true,
        .dark = systemDarkMode(),
    };
    const dark = switch (value.theme) {
        .system => systemDarkMode(),
        .light => false,
        .dark => true,
    };
    return paletteFor(dark, accentColor(value.accent, systemAccent()));
}

pub fn metricsFor(density: runtime_settings.Density) Metrics {
    return switch (density) {
        .compact => .{ .font_height = 16, .row_height = 28, .horizontal_padding = 12, .outer_padding = 4, .corner_radius = 8 },
        .comfortable => .{ .font_height = 17, .row_height = 34, .horizontal_padding = 14, .outer_padding = 6, .corner_radius = 10 },
    };
}
