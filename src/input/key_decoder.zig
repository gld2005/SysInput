const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const language_gate = sysinput.input.language_gate;

pub const ModifierState = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift_mask: u8 = 0,
    ctrl_mask: u8 = 0,
    alt_mask: u8 = 0,

    fn setMask(mask: *u8, bit: u8, is_down: bool) void {
        if (is_down) {
            mask.* |= bit;
        } else {
            mask.* &= ~bit;
        }
    }

    pub fn update(self: *ModifierState, vk_code: api.DWORD, is_down: bool) bool {
        switch (vk_code) {
            api.VK_SHIFT => setMask(&self.shift_mask, 0b001, is_down),
            api.VK_LSHIFT => setMask(&self.shift_mask, 0b010, is_down),
            api.VK_RSHIFT => setMask(&self.shift_mask, 0b100, is_down),
            api.VK_CONTROL => setMask(&self.ctrl_mask, 0b001, is_down),
            api.VK_LCONTROL => setMask(&self.ctrl_mask, 0b010, is_down),
            api.VK_RCONTROL => setMask(&self.ctrl_mask, 0b100, is_down),
            api.VK_MENU => setMask(&self.alt_mask, 0b001, is_down),
            api.VK_LMENU => setMask(&self.alt_mask, 0b010, is_down),
            api.VK_RMENU => setMask(&self.alt_mask, 0b100, is_down),
            else => return false,
        }
        self.shift = self.shift_mask != 0;
        self.ctrl = self.ctrl_mask != 0;
        self.alt = self.alt_mask != 0;
        return true;
    }
};

pub const KeyboardDecoder = struct {
    modifiers: ModifierState = .{},

    pub fn observeModifier(self: *KeyboardDecoder, vk_code: api.DWORD, is_down: bool) bool {
        return self.modifiers.update(vk_code, is_down);
    }

    /// Translate a physical key through the foreground application's active
    /// keyboard layout. SysInput currently accepts printable ASCII only.
    pub fn decodeEnglishAscii(self: *const KeyboardDecoder, event: *const api.KBDLLHOOKSTRUCT) ?u8 {
        if (self.modifiers.ctrl or self.modifiers.alt) return null;

        var keyboard_state = [_]api.BYTE{0} ** 256;
        if (api.GetKeyboardState(&keyboard_state) == 0) return null;

        keyboard_state[api.VK_SHIFT] = if (self.modifiers.shift) 0x80 else 0;
        keyboard_state[api.VK_CONTROL] = if (self.modifiers.ctrl) 0x80 else 0;
        keyboard_state[api.VK_MENU] = if (self.modifiers.alt) 0x80 else 0;
        if (event.vkCode < keyboard_state.len) {
            keyboard_state[event.vkCode] |= 0x80;
        }

        keyboard_state[api.VK_CAPITAL] = @intCast(api.GetKeyState(api.VK_CAPITAL) & 1);

        const foreground = api.GetForegroundWindow();
        const thread_id = if (foreground) |hwnd|
            api.GetWindowThreadProcessId(hwnd, null)
        else
            0;
        const layout = api.GetKeyboardLayout(thread_id);
        if (!language_gate.isEnglishLayout(layout)) return null;

        var utf16 = [_]api.WCHAR{0} ** 4;
        const translated = api.ToUnicodeEx(
            event.vkCode,
            event.scanCode,
            &keyboard_state,
            &utf16,
            utf16.len,
            api.TO_UNICODE_NO_STATE_CHANGE,
            layout,
        );

        if (translated != 1) return null;
        const code_unit = utf16[0];
        if (code_unit < 0x20 or code_unit > 0x7E) return null;
        return @intCast(code_unit);
    }
};

pub fn isInjected(flags: api.DWORD) bool {
    return (flags & (api.LLKHF_INJECTED | api.LLKHF_LOWER_IL_INJECTED)) != 0;
}

pub fn isModifier(vk_code: api.DWORD) bool {
    return switch (vk_code) {
        api.VK_SHIFT,
        api.VK_LSHIFT,
        api.VK_RSHIFT,
        api.VK_CONTROL,
        api.VK_LCONTROL,
        api.VK_RCONTROL,
        api.VK_MENU,
        api.VK_LMENU,
        api.VK_RMENU,
        => true,
        else => false,
    };
}
