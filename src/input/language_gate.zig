const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;

pub const LANG_ENGLISH: u16 = 0x09;
const PRIMARY_LANGUAGE_MASK: u16 = 0x03ff;

pub fn primaryLanguage(language_id: u16) u16 {
    return language_id & PRIMARY_LANGUAGE_MASK;
}

pub fn isEnglishLanguageId(language_id: u16) bool {
    return primaryLanguage(language_id) == LANG_ENGLISH;
}

pub fn languageIdFromLayoutValue(layout_value: usize) u16 {
    return @truncate(layout_value);
}

pub fn isEnglishLayout(layout: api.HKL) bool {
    return isEnglishLanguageId(languageIdFromLayoutValue(@intFromPtr(layout)));
}

/// Resolves the input language owned by the target GUI thread. This function
/// performs no allocation, process lookup, disk I/O, or IME composition query.
pub fn isEnglishForWindow(window: ?api.HWND) bool {
    const target = window orelse return false;
    const thread_id = api.GetWindowThreadProcessId(target, null);
    if (thread_id == 0) return false;
    return isEnglishLayout(api.GetKeyboardLayout(thread_id));
}

pub fn isEnglishForeground() bool {
    return isEnglishForWindow(api.GetForegroundWindow());
}
