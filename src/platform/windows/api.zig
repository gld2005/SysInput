//-----------------------------------------------------------------------------
// Windows API bindings for Zig
// Organized by functional areas
//-----------------------------------------------------------------------------

const std = @import("std");

//=============================================================================
// BASIC TYPES AND HANDLES
//=============================================================================

// Basic Windows Types
pub const BOOL = i32;
pub const UINT = u32;
pub const DWORD = u32;
pub const WORD = u16;
pub const WCHAR = u16;
pub const LONG = i32;
pub const LPARAM = isize;
pub const WPARAM = usize;
pub const LRESULT = isize;
pub const ATOM = u16;
pub const COLORREF = u32; // RGB color value

// Handle Types
pub const HANDLE = *anyopaque;
pub const HWND = *anyopaque; // Window handle
pub const HINSTANCE = *anyopaque; // Instance handle
pub const HHOOK = HANDLE; // Hook handle
pub const HDC = *anyopaque; // Device context handle
pub const HFONT = *anyopaque; // Font handle
pub const HGDIOBJ = *anyopaque; // GDI object handle
pub const HBRUSH = *anyopaque; // Brush handle
pub const HKL = HANDLE; // Keyboard layout handle
pub const HICON = HANDLE;
pub const HMENU = HANDLE;
pub const HKEY = HANDLE;

//=============================================================================
// WINDOW MESSAGE CONSTANTS
//=============================================================================

// Basic Window Messages
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_CLOSE = 0x0010;
pub const WM_PAINT = 0x000F;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_COMMAND = 0x0111;
pub const WM_SETFONT = 0x0030;
pub const WM_CONTEXTMENU = 0x007B;
pub const WM_NULL = 0x0000;
pub const WM_USER = 0x0400;
pub const WM_APP = 0x8000;

// Input-related Window Messages
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONUP = 0x0205;

// Text-related Window Messages
pub const WM_GETTEXT = 0x000D;
pub const WM_SETTEXT = 0x000C;
pub const WM_GETTEXTLENGTH = 0x000E;
pub const WM_PASTE = 0x0302;

// Edit Control Messages
pub const EM_GETSEL = 0x00B0;
pub const EM_SETSEL = 0x00B1;
pub const EM_REPLACESEL = 0x00C2;
pub const EM_POSFROMCHAR = 0x00D6;

//=============================================================================
// KEYBOARD AND INPUT CONSTANTS
//=============================================================================

// Hook types
pub const WH_KEYBOARD_LL = 13;
pub const HC_ACTION = 0;

// Input types
pub const INPUT_KEYBOARD = 1;
pub const KEYEVENTF_KEYUP = 0x0002;
pub const KEYEVENTF_UNICODE = 0x0004;
pub const LLKHF_LOWER_IL_INJECTED = 0x00000002;
pub const LLKHF_INJECTED = 0x00000010;
pub const TO_UNICODE_NO_STATE_CHANGE = 0x00000004;

// Virtual Key Constants
pub const VK_ESCAPE = 0x1B;
pub const VK_RETURN = 0x0D;
pub const VK_SPACE = 0x20;
pub const VK_BACK = 0x08; // Backspace
pub const VK_DELETE = 0x2E; // Delete key
pub const VK_LEFT = 0x25; // Left arrow
pub const VK_RIGHT = 0x27; // Right arrow
pub const VK_UP = 0x26; // Up arrow
pub const VK_DOWN = 0x28; // Down arrow
pub const VK_HOME = 0x24; // Home key
pub const VK_END = 0x23; // End key
pub const VK_TAB = 0x09; // Tab key
pub const VK_SHIFT = 0x10; // Shift key
pub const VK_CONTROL = 0x11; // Control key
pub const VK_MENU = 0x12; // Alt key
pub const VK_CAPITAL = 0x14; // Caps Lock
pub const VK_PRIOR = 0x21; // Page Up
pub const VK_NEXT = 0x22; // Page Down
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;
pub const VK_LCONTROL = 0xA2;
pub const VK_RCONTROL = 0xA3;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;

//=============================================================================
// WINDOW STYLE AND APPEARANCE CONSTANTS
//=============================================================================

// Window positioning constants
pub const HWND_TOPMOST: ?HWND = @ptrFromInt(0xFFFFFFFF); // -1 as unsigned
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_SHOWWINDOW = 0x0040;

// Window style constants
pub const WS_POPUP = 0x80000000;
pub const WS_BORDER = 0x00800000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_CHILD = 0x40000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_TABSTOP = 0x00010000;
pub const WS_GROUP = 0x00020000;
pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const WS_VSCROLL = 0x00200000;
pub const WS_EX_CLIENTEDGE = 0x00000200;
pub const WS_EX_APPWINDOW = 0x00040000;
pub const CW_USEDEFAULT: c_int = -2147483648;
pub const BS_PUSHBUTTON = 0x00000000;
pub const BS_AUTOCHECKBOX = 0x00000003;
pub const BS_GROUPBOX = 0x00000007;
pub const BST_UNCHECKED = 0;
pub const BST_CHECKED = 1;
pub const BM_GETCHECK = 0x00F0;
pub const BM_SETCHECK = 0x00F1;
pub const LBS_NOTIFY = 0x0001;
pub const LB_ADDSTRING = 0x0180;
pub const LB_RESETCONTENT = 0x0184;
pub const LB_GETCURSEL = 0x0188;
pub const LB_ERR: LRESULT = -1;
pub const BN_CLICKED = 0;
pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WS_EX_NOACTIVATE = 0x08000000;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const GWL_EXSTYLE = -20;
pub const GWL_STYLE = -16;
pub const ES_PASSWORD: usize = 0x0020;
pub const ES_MULTILINE: usize = 0x0004;
pub const ES_AUTOVSCROLL: usize = 0x0040;
pub const ES_AUTOHSCROLL: usize = 0x0080;
pub const EN_CHANGE = 0x0300;
pub const MB_OK = 0x00000000;
pub const MB_YESNO = 0x00000004;
pub const MB_ICONWARNING = 0x00000030;
pub const IDYES = 6;
pub const CS_DROPSHADOW = 0x00020000;

// Window display commands
pub const SW_SHOW = 5;
pub const SW_SHOWNOACTIVATE = 4;
pub const SW_HIDE = 0;

//=============================================================================
// UI AND DRAWING CONSTANTS
//=============================================================================

// System metrics constants
pub const SM_CXSCREEN = 0;
pub const SM_CYSCREEN = 1;

// Text drawing constants
pub const DT_LEFT = 0x00000000;
pub const DT_SINGLELINE = 0x00000020;
pub const DT_VCENTER = 0x00000004;
pub const TRANSPARENT = 1;

// Drawing constants
pub const NULL_PEN = 8;
pub const CLEARTYPE_QUALITY = 5;
pub const BYTE = u8;

// Font constants
pub const FW_NORMAL = 400;
pub const ANSI_CHARSET = 0;
pub const OUT_DEFAULT_PRECIS = 0;
pub const CLIP_DEFAULT_PRECIS = 0;
pub const DEFAULT_QUALITY = 0;
pub const DEFAULT_PITCH = 0;
pub const FF_DONTCARE = 0;

// Stock object constants
pub const WHITE_BRUSH = 0;
pub const DEFAULT_GUI_FONT = 17;
pub const LTGRAY_BRUSH = 1;
pub const GRAY_BRUSH = 2;
pub const DKGRAY_BRUSH = 3;
pub const BLACK_BRUSH = 4;
pub const NULL_BRUSH = 5;
pub const WHITE_PEN = 6;
pub const BLACK_PEN = 7;
pub const PS_SOLID = 0;

// Cursor constants
pub const IDC_ARROW = 32512;
pub const IDI_APPLICATION = 32512;

// Popup menu constants
pub const MF_STRING = 0x00000000;
pub const MF_SEPARATOR = 0x00000800;
pub const MF_CHECKED = 0x00000008;
pub const MF_GRAYED = 0x00000001;
pub const TPM_RIGHTBUTTON = 0x0002;
pub const TPM_RETURNCMD = 0x0100;

// Shell notification constants
pub const NIM_ADD = 0x00000000;
pub const NIM_MODIFY = 0x00000001;
pub const NIM_DELETE = 0x00000002;
pub const NIM_SETVERSION = 0x00000004;
pub const NIF_MESSAGE = 0x00000001;
pub const NIF_ICON = 0x00000002;
pub const NIF_TIP = 0x00000004;
pub const NOTIFYICON_VERSION_4 = 4;

// Registry and kernel constants
pub const ERROR_SUCCESS = 0;
pub const ERROR_FILE_NOT_FOUND = 2;
pub const ERROR_ALREADY_EXISTS = 183;
pub const REG_SZ = 1;
pub const REG_DWORD = 4;
pub const KEY_QUERY_VALUE = 0x0001;
pub const KEY_SET_VALUE = 0x0002;
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
pub const TOKEN_QUERY = 0x0008;
pub const TokenIntegrityLevel = 25;

// Layered window constants
pub const LWA_ALPHA = 0x00000002;
pub const LWA_COLORKEY = 0x00000001;

// Clipboard constants
pub const CF_TEXT = 1;
pub const GMEM_MOVEABLE = 0x0002;

// Display metrics constants
pub const LOGPIXELSY = 90;
pub const LOGPIXELSX = 88;

//=============================================================================
// STRUCTURES
//=============================================================================

// Keyboard Hook Structure
pub const KBDLLHOOKSTRUCT = extern struct {
    vkCode: DWORD,
    scanCode: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};

// Point structure
pub const POINT = extern struct {
    x: c_long,
    y: c_long,
};

// Rectangle structure
pub const RECT = extern struct {
    left: c_long,
    top: c_long,
    right: c_long,
    bottom: c_long,
};

// Paint structure
pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

// Window class extended structure
pub const WNDCLASSEX = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.C) LRESULT,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?HANDLE,
    hCursor: ?HANDLE,
    hbrBackground: HANDLE,
    lpszMenuName: ?[*:0]const u8,
    lpszClassName: [*:0]const u8,
    hIconSm: ?HANDLE,
};

// Message structure
pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

// Input structure definitions
pub const KEYBDINPUT = extern struct {
    wVk: WORD,
    wScan: WORD,
    dwFlags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
    padding1: DWORD,
    padding2: DWORD,
};

pub const MOUSEINPUT = extern struct {
    dx: LONG,
    dy: LONG,
    mouseData: DWORD,
    dwFlags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};

pub const HARDWAREINPUT = extern struct {
    uMsg: DWORD,
    wParamL: WORD,
    wParamH: WORD,
};

pub const INPUT = extern struct {
    type: DWORD,
    // Zig doesn't support C unions directly, so we use the largest member
    // and access the different fields depending on the type
    ki: KEYBDINPUT,
};

// GUI Thread Info structure
pub const GUITHREADINFO = extern struct {
    cbSize: DWORD,
    flags: DWORD,
    hwndActive: ?HWND,
    hwndFocus: ?HWND,
    hwndCapture: ?HWND,
    hwndMenuOwner: ?HWND,
    hwndMoveSize: ?HWND,
    hwndCaret: ?HWND,
    rcCaret: RECT,
};

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};
pub const HRESULT = i32;
pub const CLSCTX_INPROC_SERVER = 0x1;
pub const COINIT_MULTITHREADED = 0x0;
pub const VT_BOOL: u16 = 11;

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: *anyopaque,
    Attributes: DWORD,
};

pub const TOKEN_MANDATORY_LABEL = extern struct {
    Label: SID_AND_ATTRIBUTES,
};

pub const OPENFILENAMEA = extern struct {
    lStructSize: DWORD,
    hwndOwner: ?HWND,
    hInstance: ?HINSTANCE,
    lpstrFilter: ?[*:0]const u8,
    lpstrCustomFilter: ?[*:0]u8,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: [*:0]u8,
    nMaxFile: DWORD,
    lpstrFileTitle: ?[*:0]u8,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: ?[*:0]const u8,
    lpstrTitle: ?[*:0]const u8,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: ?[*:0]const u8,
    lCustData: LPARAM,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?[*:0]const u8,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};

pub const OFN_FILEMUSTEXIST = 0x00001000;
pub const OFN_PATHMUSTEXIST = 0x00000800;
pub const OFN_NOCHANGEDIR = 0x00000008;

pub const NOTIFYICONDATAA = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]u8,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u8,
    uTimeoutOrVersion: UINT,
    szInfoTitle: [64]u8,
    dwInfoFlags: DWORD,
    guidItem: GUID,
    hBalloonIcon: ?HICON,
};

//=============================================================================
// ERROR TYPES
//=============================================================================

// Common error types
pub const HookError = error{
    SetHookFailed,
    UnhookFailed,
    MessageLoopFailed,
};

//=============================================================================
// WINDOW MANAGEMENT FUNCTIONS
//=============================================================================

// Window creation and management
pub extern "user32" fn CreateWindowExA(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u8,
    lpWindowName: [*:0]const u8,
    dwStyle: DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HANDLE,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.C) ?HWND;

pub extern "user32" fn ShowWindow(
    hWnd: HWND,
    nCmdShow: c_int,
) callconv(.C) BOOL;

pub extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(.C) BOOL;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.C) BOOL;
pub extern "user32" fn SetWindowTextA(hWnd: HWND, lpString: [*:0]const u8) callconv(.C) BOOL;

pub extern "user32" fn UpdateWindow(
    hWnd: HWND,
) callconv(.C) BOOL;

pub extern "user32" fn DestroyWindow(
    hWnd: HWND,
) callconv(.C) BOOL;

pub extern "user32" fn GetClientRect(
    hWnd: HWND,
    lpRect: *RECT,
) callconv(.C) BOOL;

pub extern "user32" fn GetWindowRect(
    hWnd: HWND,
    lpRect: *RECT,
) callconv(.C) BOOL;

pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    X: c_int,
    Y: c_int,
    cx: c_int,
    cy: c_int,
    uFlags: UINT,
) callconv(.C) BOOL;

pub extern "user32" fn InvalidateRect(
    hWnd: ?HWND,
    lpRect: ?*const RECT,
    bErase: BOOL,
) callconv(.C) BOOL;

pub extern "user32" fn RegisterClassExA(
    lpWndClass: *const WNDCLASSEX,
) callconv(.C) ATOM;

pub extern "user32" fn UnregisterClassA(
    lpClassName: [*:0]const u8,
    hInstance: HINSTANCE,
) callconv(.C) BOOL;

pub extern "user32" fn DefWindowProcA(
    hWnd: HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.C) LRESULT;

pub extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.C) void;
pub extern "user32" fn CreatePopupMenu() callconv(.C) ?HMENU;
pub extern "user32" fn AppendMenuA(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u8) callconv(.C) BOOL;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.C) BOOL;
pub extern "user32" fn TrackPopupMenu(
    hMenu: HMENU,
    uFlags: UINT,
    x: c_int,
    y: c_int,
    nReserved: c_int,
    hWnd: HWND,
    prcRect: ?*const RECT,
) callconv(.C) UINT;

pub extern "user32" fn GetActiveWindow() callconv(.C) ?HWND;
pub extern "user32" fn GetParent(hWnd: HWND) callconv(.C) ?HWND;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.C) BOOL;

pub extern "user32" fn FindWindowExA(
    hWndParent: ?HWND,
    hWndChildAfter: ?HWND,
    lpszClass: [*:0]const u8,
    lpszWindow: ?[*:0]const u8,
) callconv(.C) ?HWND;

pub extern "user32" fn GetForegroundWindow() callconv(.C) ?HWND;
pub extern "user32" fn GetClassNameA(hWnd: ?HWND, lpClassName: [*:0]u8, nMaxCount: c_int) callconv(.C) c_int;
pub extern "user32" fn GetFocus() callconv(.C) ?HWND;
pub extern "user32" fn GetWindowLongPtrA(hWnd: HWND, nIndex: c_int) callconv(.C) isize;
pub extern "user32" fn GetWindowTextA(hWnd: HWND, lpString: [*:0]u8, nMaxCount: c_int) callconv(.C) c_int;
pub extern "user32" fn MessageBoxA(hWnd: ?HWND, lpText: [*:0]const u8, lpCaption: [*:0]const u8, uType: UINT) callconv(.C) c_int;

pub extern "user32" fn SendMessageA(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT;
pub extern "user32" fn PostMessageA(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.C) BOOL;
pub extern "user32" fn PostThreadMessageA(idThread: DWORD, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.C) BOOL;

pub extern "user32" fn SetLayeredWindowAttributes(
    hwnd: HWND,
    crKey: COLORREF,
    bAlpha: BYTE,
    dwFlags: DWORD,
) callconv(.C) BOOL;

pub extern "gdi32" fn RoundRect(
    hdc: HDC,
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
    width: c_int,
    height: c_int,
) callconv(.C) BOOL;

//=============================================================================
// INPUT AND CURSOR FUNCTIONS
//=============================================================================

// Keyboard and mouse input
pub extern "user32" fn SendInput(
    cInputs: UINT,
    pInputs: *const INPUT,
    cbSize: c_int,
) callconv(.C) UINT;

pub extern "user32" fn GetKeyboardState(lpKeyState: *[256]BYTE) callconv(.C) BOOL;
pub extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.C) i16;
pub extern "user32" fn GetKeyboardLayout(idThread: DWORD) callconv(.C) HKL;
pub extern "user32" fn ToUnicodeEx(
    wVirtKey: UINT,
    wScanCode: UINT,
    lpKeyState: *const [256]BYTE,
    pwszBuff: [*]WCHAR,
    cchBuff: c_int,
    wFlags: UINT,
    dwhkl: HKL,
) callconv(.C) c_int;

// Cursor and caret management
pub extern "user32" fn GetCursorPos(
    lpPoint: *POINT,
) callconv(.C) BOOL;

pub extern "user32" fn GetCaretPos(
    lpPoint: *POINT,
) callconv(.C) BOOL;

pub extern "user32" fn ClientToScreen(
    hWnd: HWND,
    lpPoint: *POINT,
) callconv(.C) BOOL;

pub extern "user32" fn LoadCursorA(
    hInstance: ?HINSTANCE,
    lpCursorName: [*:0]const u8,
) callconv(.C) ?HANDLE;
pub extern "user32" fn LoadIconA(hInstance: ?HINSTANCE, lpIconName: [*:0]const u8) callconv(.C) ?HICON;

pub extern "shell32" fn Shell_NotifyIconA(dwMessage: DWORD, lpData: *NOTIFYICONDATAA) callconv(.C) BOOL;
pub extern "comdlg32" fn GetOpenFileNameA(param: *OPENFILENAMEA) callconv(.C) BOOL;
pub extern "comdlg32" fn GetSaveFileNameA(param: *OPENFILENAMEA) callconv(.C) BOOL;
pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.C) HRESULT;
pub extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: DWORD, riid: *const GUID, ppv: **anyopaque) callconv(.C) HRESULT;
pub extern "oleaut32" fn VariantClear(pvarg: *anyopaque) callconv(.C) HRESULT;

// Thread and process info
pub extern "user32" fn GetWindowThreadProcessId(
    hWnd: HWND,
    lpdwProcessId: ?*DWORD,
) callconv(.C) DWORD;

pub extern "user32" fn GetGUIThreadInfo(
    idThread: DWORD,
    pgui: *GUITHREADINFO,
) callconv(.C) BOOL;

//=============================================================================
// GRAPHICS AND DRAWING FUNCTIONS
//=============================================================================

// Device context
pub extern "user32" fn GetDC(
    hWnd: ?HWND,
) callconv(.C) ?HDC;

pub extern "user32" fn ReleaseDC(
    hWnd: ?HWND,
    hDC: HDC,
) callconv(.C) c_int;

pub extern "gdi32" fn GetDeviceCaps(
    hdc: HDC,
    nIndex: c_int,
) callconv(.C) c_int;

// Paint functions
pub extern "user32" fn BeginPaint(
    hWnd: HWND,
    lpPaint: *PAINTSTRUCT,
) callconv(.C) HDC;

pub extern "user32" fn EndPaint(
    hWnd: HWND,
    lpPaint: *const PAINTSTRUCT,
) callconv(.C) BOOL;

pub extern "user32" fn FillRect(
    hDC: HDC,
    lprc: *const RECT,
    hbr: HANDLE,
) callconv(.C) c_int;

pub extern "user32" fn DrawTextA(
    hdc: HDC,
    lpchText: [*:0]const u8,
    cchText: c_int,
    lprc: *RECT,
    format: UINT,
) callconv(.C) c_int;

// GDI objects
pub extern "gdi32" fn GetStockObject(
    fnObject: c_int,
) callconv(.C) ?HGDIOBJ;

pub extern "gdi32" fn CreateFontA(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: [*:0]const u8,
) callconv(.C) ?HFONT;

pub extern "gdi32" fn CreateSolidBrush(
    color: COLORREF,
) callconv(.C) ?HBRUSH;

pub extern "gdi32" fn SelectObject(
    hdc: HDC,
    h: HGDIOBJ,
) callconv(.C) ?HGDIOBJ;

pub extern "gdi32" fn DeleteObject(
    ho: HGDIOBJ,
) callconv(.C) BOOL;

pub extern "gdi32" fn SetTextColor(
    hdc: HDC,
    color: COLORREF,
) callconv(.C) COLORREF;

pub extern "gdi32" fn SetBkMode(
    hdc: HDC,
    mode: c_int,
) callconv(.C) c_int;

//=============================================================================
// CLIPBOARD FUNCTIONS
//=============================================================================

pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.C) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.C) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.C) BOOL;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?HANDLE) callconv(.C) ?HANDLE;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.C) ?HANDLE;

//=============================================================================
// MEMORY MANAGEMENT FUNCTIONS
//=============================================================================

pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.C) ?HANDLE;
pub extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.C) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.C) BOOL;
pub extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(.C) HANDLE;

//=============================================================================
// SYSTEM INFORMATION FUNCTIONS
//=============================================================================

pub extern "user32" fn GetSystemMetrics(
    nIndex: c_int,
) callconv(.C) c_int;

//=============================================================================
// UTILITY FUNCTIONS
//=============================================================================

// Miscellaneous utility functions
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.C) void;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.C) DWORD;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.C) DWORD;
pub extern "kernel32" fn GetCurrentProcess() callconv(.C) HANDLE;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.C) ?HANDLE;
pub extern "kernel32" fn QueryFullProcessImageNameA(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u8, lpdwSize: *DWORD) callconv(.C) BOOL;
pub extern "kernel32" fn lstrlenA(lpString: ?*const anyopaque) callconv(.C) c_int;
pub extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: BOOL, lpName: [*:0]const u8) callconv(.C) ?HANDLE;
pub extern "kernel32" fn GetLastError() callconv(.C) DWORD;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.C) BOOL;

pub extern "advapi32" fn RegCreateKeyExA(
    hKey: HKEY,
    lpSubKey: [*:0]const u8,
    Reserved: DWORD,
    lpClass: ?[*:0]u8,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.C) LONG;
pub extern "advapi32" fn RegOpenKeyExA(hKey: HKEY, lpSubKey: [*:0]const u8, ulOptions: DWORD, samDesired: DWORD, phkResult: *HKEY) callconv(.C) LONG;
pub extern "advapi32" fn RegSetValueExA(hKey: HKEY, lpValueName: [*:0]const u8, Reserved: DWORD, dwType: DWORD, lpData: [*]const u8, cbData: DWORD) callconv(.C) LONG;
pub extern "advapi32" fn RegQueryValueExA(hKey: HKEY, lpValueName: [*:0]const u8, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?[*]u8, lpcbData: ?*DWORD) callconv(.C) LONG;
pub extern "advapi32" fn RegDeleteValueA(hKey: HKEY, lpValueName: [*:0]const u8) callconv(.C) LONG;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.C) LONG;
pub extern "advapi32" fn OpenProcessToken(ProcessHandle: HANDLE, DesiredAccess: DWORD, TokenHandle: *HANDLE) callconv(.C) BOOL;
pub extern "advapi32" fn GetTokenInformation(TokenHandle: HANDLE, TokenInformationClass: c_int, TokenInformation: *anyopaque, TokenInformationLength: DWORD, ReturnLength: *DWORD) callconv(.C) BOOL;
pub extern "advapi32" fn GetSidSubAuthorityCount(pSid: *anyopaque) callconv(.C) ?*u8;
pub extern "advapi32" fn GetSidSubAuthority(pSid: *anyopaque, nSubAuthority: DWORD) callconv(.C) ?*DWORD;

// Helper functions
pub inline fn makeIntResource(id: u16) [*:0]const u8 {
    return @ptrFromInt(id);
}

//=============================================================================
// IDIOMATIC ZIG WRAPPERS
//=============================================================================

// --- Window Management ---

// Original SafeWrapper functions
pub fn safeGetClassName(hwnd: ?HWND) ![]const u8 {
    var class_name: [256]u8 = undefined;
    const len = GetClassNameA(hwnd, @ptrCast(&class_name), class_name.len);
    if (len == 0) return error.GetClassNameFailed;
    return class_name[0..@as(usize, @intCast(len))];
}

pub fn safeGetFocus() !HWND {
    return GetFocus() orelse error.NoFocusedWindow;
}

pub fn safeGetForegroundWindow() !HWND {
    return GetForegroundWindow() orelse error.NoActiveWindow;
}

// camelCase API wrappers for common functions
pub fn getClassName(hwnd: ?HWND, className: [*:0]u8, maxCount: c_int) c_int {
    return GetClassNameA(hwnd, className, maxCount);
}

pub fn getFocus() ?HWND {
    return GetFocus();
}

pub fn getForegroundWindow() ?HWND {
    return GetForegroundWindow();
}

pub fn getActiveWindow() ?HWND {
    return GetActiveWindow();
}

pub fn getParent(hwnd: HWND) ?HWND {
    return GetParent(hwnd);
}

pub fn clientToScreen(hwnd: HWND, point: *POINT) BOOL {
    return ClientToScreen(hwnd, point);
}

pub fn getClientRect(hwnd: HWND, rect: *RECT) BOOL {
    return GetClientRect(hwnd, rect);
}

pub fn getWindowRect(hwnd: HWND, rect: *RECT) BOOL {
    return GetWindowRect(hwnd, rect);
}

pub fn getCaretPos(point: *POINT) BOOL {
    return GetCaretPos(point);
}

pub fn getCursorPos(point: *POINT) BOOL {
    return GetCursorPos(point);
}

pub fn setForegroundWindow(hwnd: HWND) BOOL {
    return SetForegroundWindow(hwnd);
}

pub fn findWindowEx(parent: ?HWND, childAfter: ?HWND, className: [*:0]const u8, windowName: ?[*:0]const u8) ?HWND {
    return FindWindowExA(parent, childAfter, className, windowName);
}

pub fn sendMessage(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) LRESULT {
    return SendMessageA(hwnd, msg, wParam, lParam);
}

pub fn postMessage(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) BOOL {
    return PostMessageA(hwnd, msg, wParam, lParam);
}

pub fn sendInput(inputCount: UINT, inputs: *const INPUT, inputSize: c_int) UINT {
    return SendInput(inputCount, inputs, inputSize);
}

pub fn setWindowPos(hwnd: HWND, insertAfter: ?HWND, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: UINT) BOOL {
    return SetWindowPos(hwnd, insertAfter, x, y, cx, cy, flags);
}

pub fn getWindowThreadProcessId(hwnd: HWND, processId: ?*DWORD) DWORD {
    return GetWindowThreadProcessId(hwnd, processId);
}

pub fn getGUIThreadInfo(threadId: DWORD, info: *GUITHREADINFO) BOOL {
    return GetGUIThreadInfo(threadId, info);
}

/// Resolve the focused control belonging to the foreground GUI thread.
/// GetFocus() only describes the caller's thread and is insufficient for a
/// system-wide input helper.
pub fn getFocusedWindow() ?HWND {
    const foreground = GetForegroundWindow() orelse return null;
    const thread_id = GetWindowThreadProcessId(foreground, null);
    if (thread_id == 0) return foreground;

    var info = std.mem.zeroes(GUITHREADINFO);
    info.cbSize = @sizeOf(GUITHREADINFO);
    if (GetGUIThreadInfo(thread_id, &info) == 0) return foreground;
    return info.hwndFocus orelse foreground;
}

// --- Device Context and Drawing ---

pub fn getDC(hwnd: ?HWND) ?HDC {
    return GetDC(hwnd);
}

pub fn releaseDC(hwnd: ?HWND, hdc: HDC) c_int {
    return ReleaseDC(hwnd, hdc);
}

pub fn beginPaint(hwnd: HWND, paint: *PAINTSTRUCT) HDC {
    return BeginPaint(hwnd, paint);
}

pub fn endPaint(hwnd: HWND, paint: *const PAINTSTRUCT) BOOL {
    return EndPaint(hwnd, paint);
}

pub fn fillRect(hdc: HDC, rect: *const RECT, brush: HANDLE) c_int {
    return FillRect(hdc, rect, brush);
}

pub fn drawText(hdc: HDC, text: [*:0]const u8, textLen: c_int, rect: *RECT, format: UINT) c_int {
    return DrawTextA(hdc, text, textLen, rect, format);
}

// --- Clipboard Operations ---

pub fn openClipboard(hwndOwner: ?HWND) BOOL {
    return OpenClipboard(hwndOwner);
}

pub fn closeClipboard() BOOL {
    return CloseClipboard();
}

pub fn emptyClipboard() BOOL {
    return EmptyClipboard();
}

pub fn setClipboardData(format: UINT, mem: ?HANDLE) ?HANDLE {
    return SetClipboardData(format, mem);
}

pub fn getClipboardData(format: UINT) ?HANDLE {
    return GetClipboardData(format);
}

// --- Memory Operations ---

pub fn globalAlloc(flags: UINT, bytes: usize) ?HANDLE {
    return GlobalAlloc(flags, bytes);
}

pub fn globalLock(mem: HANDLE) ?*anyopaque {
    return GlobalLock(mem);
}

pub fn globalUnlock(mem: HANDLE) BOOL {
    return GlobalUnlock(mem);
}

pub fn globalFree(mem: HANDLE) HANDLE {
    return GlobalFree(mem);
}

// --- System Information ---

pub fn getSystemMetrics(index: c_int) c_int {
    return GetSystemMetrics(index);
}

// --- Utility Functions ---

pub fn sleep(milliseconds: DWORD) void {
    return Sleep(milliseconds);
}
