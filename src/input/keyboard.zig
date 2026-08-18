const std = @import("std");
const sysinput = @import("root").sysinput;

const win32 = sysinput.win32.hook;
const api = sysinput.win32.api;
const buffer_controller = sysinput.core.buffer_controller;
const manager = sysinput.suggestion.manager;
const debug = sysinput.core.debug;
const key_decoder = sysinput.input.key_decoder;
const prediction_worker = sysinput.suggestion.worker;

pub var g_hook: ?win32.HHOOK = null;
var decoder = key_decoder.KeyboardDecoder{};

pub const SuggestionKeyAction = enum {
    previous,
    next,
    accept,
    hide,
    pass,
};

pub fn suggestionKeyAction(virtual_key: api.DWORD) SuggestionKeyAction {
    return switch (virtual_key) {
        win32.VK_UP => .previous,
        win32.VK_DOWN => .next,
        win32.VK_TAB, win32.VK_RIGHT => .accept,
        win32.VK_ESCAPE => .hide,
        else => .pass,
    };
}

pub fn setupKeyboardHook() !win32.HHOOK {
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

fn processSuggestionNavigation(kbd: *const win32.KBDLLHOOKSTRUCT) win32.LRESULT {
    debug.debugPrint("Suggestion navigation key: 0x{X}\n", .{kbd.vkCode});

    switch (suggestionKeyAction(kbd.vkCode)) {
        .previous => manager.navigateToPreviousSuggestion(),
        .next => manager.navigateToNextSuggestion(),
        .accept => manager.acceptCurrentSuggestion(),
        else => return 0,
    }
    return 1;
}

fn refreshSuggestions() void {
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
        win32.VK_LEFT => {
            buffer_controller.prepareForPhysicalInput();
            buffer_controller.recordPhysicalCursorLeft();
            refreshSuggestions();
        },
        win32.VK_RIGHT => {
            buffer_controller.prepareForPhysicalInput();
            buffer_controller.recordPhysicalCursorRight();
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
    if (down or up) {
        if (decoder.observeModifier(kbd.vkCode, down)) {
            return win32.CallNextHookEx(null, nCode, wParam, lParam);
        }
    }
    if (!down) return win32.CallNextHookEx(null, nCode, wParam, lParam);

    if (manager.isSuggestionUIVisible()) {
        switch (suggestionKeyAction(kbd.vkCode)) {
            .previous, .next, .accept => return processSuggestionNavigation(kbd),
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
