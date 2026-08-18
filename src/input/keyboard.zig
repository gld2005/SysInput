const std = @import("std");
const sysinput = @import("root").sysinput;

const win32 = sysinput.win32.hook;
const api = sysinput.win32.api;
const buffer_controller = sysinput.core.buffer_controller;
const manager = sysinput.suggestion.manager;
const debug = sysinput.core.debug;
const key_decoder = sysinput.input.key_decoder;
const prediction_worker = sysinput.suggestion.worker;
const language_gate = sysinput.input.language_gate;
const position = sysinput.ui.position;

pub var g_hook: ?win32.HHOOK = null;
var decoder = key_decoder.KeyboardDecoder{};
var last_foreground_window: ?api.HWND = null;
var last_input_english: ?bool = null;

pub const SuggestionKeyAction = enum {
    previous,
    next,
    accept_chunk,
    accept_word,
    hide,
    pass,
};

pub fn suggestionKeyAction(
    virtual_key: api.DWORD,
    modifiers: key_decoder.ModifierState,
    safe_arrow_mode: bool,
) SuggestionKeyAction {
    if (!modifiers.shift and !modifiers.ctrl and !modifiers.alt) {
        return switch (virtual_key) {
            win32.VK_TAB => .accept_chunk,
            win32.VK_ESCAPE => .hide,
            win32.VK_RIGHT => if (safe_arrow_mode) .pass else .accept_word,
            win32.VK_UP => if (safe_arrow_mode) .pass else .previous,
            win32.VK_DOWN => if (safe_arrow_mode) .pass else .next,
            else => .pass,
        };
    }
    if (modifiers.ctrl and !modifiers.shift and !modifiers.alt and virtual_key == win32.VK_RIGHT) {
        return .accept_word;
    }
    if (modifiers.alt and !modifiers.shift and !modifiers.ctrl) {
        return switch (virtual_key) {
            win32.VK_UP => .previous,
            win32.VK_DOWN => .next,
            else => .pass,
        };
    }
    return .pass;
}

pub fn setupKeyboardHook() !win32.HHOOK {
    last_foreground_window = null;
    last_input_english = null;
    const hInstance = win32.GetModuleHandleA(null);
    const hook = win32.SetWindowsHookExA(win32.WH_KEYBOARD_LL, keyboardHookProc, hInstance, 0);

    if (hook == null) {
        debug.debugPrint("Failed to set keyboard hook\n", .{});
        return win32.HookError.SetHookFailed;
    }

    return hook.?;
}

fn isKeyDown(message: win32.WPARAM) bool {
    return message == win32.WM_KEYDOWN or message == win32.WM_SYSKEYDOWN;
}

fn isKeyUp(message: win32.WPARAM) bool {
    return message == win32.WM_KEYUP or message == win32.WM_SYSKEYUP;
}

fn processSuggestionNavigation(kbd: *const win32.KBDLLHOOKSTRUCT) bool {
    debug.debugPrint("Suggestion navigation key: 0x{X}\n", .{kbd.vkCode});

    return switch (suggestionKeyAction(kbd.vkCode, decoder.modifiers, manager.runtimeSetting(.safe_arrow_mode))) {
        .previous => manager.navigateToPreviousSuggestion(),
        .next => manager.navigateToNextSuggestion(),
        .accept_chunk => manager.acceptCurrentSuggestion(.chunk),
        .accept_word => manager.acceptCurrentSuggestion(.word),
        else => false,
    };
}

fn refreshSuggestions() void {
    // A physical edit moves the caret; never reuse the prior display anchor.
    position.invalidatePositionCache();
    const text = buffer_controller.getCurrentText();
    const word = buffer_controller.getCurrentWord() catch "";
    _ = prediction_worker.submitPrediction(text, word);
}

fn processCtrlBackspace(kbd: *const win32.KBDLLHOOKSTRUCT) bool {
    if (kbd.vkCode != win32.VK_BACK or !decoder.modifiers.ctrl) return false;

    buffer_controller.prepareForPhysicalInput();
    buffer_controller.recordPhysicalCtrlBackspace() catch |err| {
        debug.debugPrint("Ctrl+Backspace state error: {}\n", .{err});
        buffer_controller.invalidatePhysicalInputState();
    };
    refreshSuggestions();
    return true;
}

fn processNavigationWithoutSuggestions(kbd: *const win32.KBDLLHOOKSTRUCT) bool {
    switch (kbd.vkCode) {
        win32.VK_LEFT, win32.VK_RIGHT => {
            manager.hideSuggestions();
            if (decoder.modifiers.shift or decoder.modifiers.ctrl or decoder.modifiers.alt) {
                buffer_controller.invalidatePhysicalInputState();
                return true;
            }
            buffer_controller.prepareForPhysicalInput();
            if (kbd.vkCode == win32.VK_LEFT) {
                buffer_controller.recordPhysicalCursorLeft();
            } else {
                buffer_controller.recordPhysicalCursorRight();
            }
            refreshSuggestions();
        },
        win32.VK_UP,
        win32.VK_DOWN,
        win32.VK_HOME,
        win32.VK_END,
        win32.VK_PRIOR,
        win32.VK_NEXT,
        => {
            buffer_controller.invalidatePhysicalInputState();
            manager.hideSuggestions();
        },
        else => return false,
    }
    return true;
}

fn processPhysicalKey(kbd: *const win32.KBDLLHOOKSTRUCT) void {
    debug.debugPrint("Physical key down: 0x{X}\n", .{kbd.vkCode});

    if (kbd.vkCode == win32.VK_ESCAPE) {
        manager.hideSuggestions();
        buffer_controller.invalidatePhysicalInputState();
        return;
    }

    buffer_controller.prepareForPhysicalInput();

    switch (kbd.vkCode) {
        win32.VK_BACK => buffer_controller.recordPhysicalBackspace() catch |err| {
            debug.debugPrint("Backspace state error: {}\n", .{err});
            buffer_controller.invalidatePhysicalInputState();
        },
        win32.VK_DELETE => buffer_controller.recordPhysicalDelete() catch |err| {
            debug.debugPrint("Delete state error: {}\n", .{err});
            buffer_controller.invalidatePhysicalInputState();
        },
        win32.VK_RETURN => buffer_controller.recordPhysicalReturn() catch |err| {
            debug.debugPrint("Return state error: {}\n", .{err});
            buffer_controller.invalidatePhysicalInputState();
        },
        win32.VK_TAB => {
            buffer_controller.invalidatePhysicalInputState();
            manager.hideSuggestions();
            return;
        },
        else => {
            const char = decoder.decodeEnglishAscii(kbd) orelse return;
            buffer_controller.recordPhysicalChar(char) catch |err| {
                debug.debugPrint("Character state error: {}\n", .{err});
                buffer_controller.invalidatePhysicalInputState();
                return;
            };
        },
    }

    refreshSuggestions();
}

fn keyboardHookProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.C) win32.LRESULT {
    if (nCode < 0) return win32.CallNextHookEx(null, nCode, wParam, lParam);
    if (nCode != win32.HC_ACTION) return win32.CallNextHookEx(null, nCode, wParam, lParam);

    const kbd = @as(*const win32.KBDLLHOOKSTRUCT, @ptrFromInt(@as(usize, @bitCast(lParam))));

    // Injected events must reach the target application but must not re-enter
    // prediction or learning.
    if (key_decoder.isInjected(kbd.flags)) {
        return win32.CallNextHookEx(null, nCode, wParam, lParam);
    }

    const down = isKeyDown(wParam);
    const up = isKeyUp(wParam);
    var modifier_event = false;
    if (down or up) {
        modifier_event = decoder.observeModifier(kbd.vkCode, down);
    }

    const foreground = api.GetForegroundWindow();
    if (foreground != last_foreground_window) {
        last_foreground_window = foreground;
        manager.hideSuggestions();
        buffer_controller.invalidatePhysicalInputState();
        position.invalidatePositionCache();
        last_input_english = null;
    }

    // Observe both key-down and key-up so layout hotkeys hide an existing
    // popup as soon as Windows completes the input-language switch.
    const input_english = language_gate.isEnglishForWindow(foreground);
    if (last_input_english == null or last_input_english.? != input_english) {
        last_input_english = input_english;
        manager.hideSuggestions();
        buffer_controller.invalidatePhysicalInputState();
        position.invalidatePositionCache();
    }
    if (!input_english or modifier_event or !down) return win32.CallNextHookEx(null, nCode, wParam, lParam);

    if (manager.isSuggestionUIVisible()) {
        switch (suggestionKeyAction(kbd.vkCode, decoder.modifiers, manager.runtimeSetting(.safe_arrow_mode))) {
            .previous, .next, .accept_chunk, .accept_word => {
                if (processSuggestionNavigation(kbd)) return 1;
                return win32.CallNextHookEx(null, nCode, wParam, lParam);
            },
            .hide => {
                manager.hideSuggestions();
                return win32.CallNextHookEx(null, nCode, wParam, lParam);
            },
            .pass => {},
        }
    }

    if (processCtrlBackspace(kbd)) {
        return win32.CallNextHookEx(null, nCode, wParam, lParam);
    }

    if (processNavigationWithoutSuggestions(kbd)) {
        return win32.CallNextHookEx(null, nCode, wParam, lParam);
    }

    if (decoder.modifiers.ctrl or decoder.modifiers.alt or key_decoder.isModifier(kbd.vkCode)) {
        if (decoder.modifiers.ctrl or decoder.modifiers.alt) {
            manager.hideSuggestions();
            buffer_controller.invalidatePhysicalInputState();
        }
        return win32.CallNextHookEx(null, nCode, wParam, lParam);
    }

    processPhysicalKey(kbd);
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}

pub fn messageLoop() !void {
    var msg: win32.MSG = undefined;

    while (win32.GetMessageA(&msg, null, 0, 0) > 0) {
        if (msg.message == prediction_worker.WM_PREDICTION_READY) {
            prediction_worker.dispatchReady();
            continue;
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageA(&msg);
    }
}
