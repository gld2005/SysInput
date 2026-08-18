const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const window = sysinput.ui.window;
const position = sysinput.ui.position;
const debug = sysinput.core.debug;
const config = sysinput.core.config;

/// Inline completion UI manager
pub const AutocompleteUI = struct {
    /// Current suggestions
    suggestions: [][]const u8,
    /// Selected suggestion index
    selected_index: i32,
    /// Allocator for operations
    allocator: std.mem.Allocator,
    /// Whether suggestions are active
    is_visible: bool,
    /// Current text in the control
    current_text: []const u8,
    /// Current partial word
    current_word: []const u8,
    /// Current best suggestion
    current_suggestion: ?[]const u8,
    /// Window handle for suggestion UI
    suggestion_window: ?api.HWND,
    /// Module instance
    instance: api.HINSTANCE,
    /// Window class atom for suggestion window
    window_class_atom: api.ATOM,

    /// Initialize the inline completion
    pub fn init(allocator: std.mem.Allocator, instance: api.HINSTANCE) !AutocompleteUI {
        // Register window class for suggestions
        const atom = try window.registerSuggestionWindowClass(instance);

        return AutocompleteUI{
            .suggestions = &[_][]const u8{},
            .selected_index = -1,
            .allocator = allocator,
            .is_visible = false,
            .current_text = "",
            .current_word = "",
            .current_suggestion = null,
            .suggestion_window = null,
            .instance = instance,
            .window_class_atom = atom,
        };
    }

    /// Process suggestions for the current text
    pub fn showSuggestions(self: *AutocompleteUI, suggestions: [][]const u8, x: i32, y: i32) !void {
        debug.debugPrint("UI showSuggestions called with {d} suggestions\n", .{suggestions.len});

        self.suggestions = suggestions;
        self.selected_index = 0;
        window.g_ui_state.suggestions = suggestions;
        window.g_ui_state.selected_index = 0;

        // Display and navigation are intentionally read-only. Text is changed
        // only by the manager's explicit acceptance path.
        if (suggestions.len > 0) {
            self.current_suggestion = suggestions[0];
            debug.debugPrint("First suggestion: '{s}'\n", .{self.current_suggestion.?});

            // Resolve and validate the real caret before declaring the UI
            // visible. Missing caret information suppresses the popup.
            try self.showSuggestionUI(x, y);
            self.is_visible = true;

            // Force a redraw of the window if it already exists
            if (self.suggestion_window != null) {
                _ = api.InvalidateRect(self.suggestion_window.?, null, 1);
                _ = api.UpdateWindow(self.suggestion_window.?);
            }
        } else {
            self.hideSuggestions();
        }
    }

    /// Show the suggestion UI window
    fn showSuggestionUI(self: *AutocompleteUI, x: i32, y: i32) !void {
        _ = x;
        _ = y;
        // Only attempt to create or show the window if we have suggestions
        if (self.suggestions.len == 0) {
            return;
        }

        const caret = position.getCaretRect() orelse return error.CaretUnavailable;
        const size = position.calculateSuggestionWindowSize(
            self.suggestions,
            config.UI.SUGGESTION_FONT_HEIGHT,
            sysinput.ui.window.WINDOW_PADDING,
        );
        const placement = position.placeSuggestionPopup(caret, size) orelse return error.NoSafePopupPlacement;
        debug.debugPrint("Showing suggestion UI at {}, {}\n", .{ placement.x, placement.y });

        // Create window if it doesn't exist
        if (self.suggestion_window == null) {
            debug.debugPrint("Creating suggestion window\n", .{});

            const new_window = api.CreateWindowExA(
                config.WIN32.SUGGESTION_WINDOW_EX_STYLE,
                sysinput.ui.window.SUGGESTION_WINDOW_CLASS,
                "Suggestions\x00",
                config.WIN32.SUGGESTION_WINDOW_STYLE,
                placement.x,
                placement.y,
                placement.width,
                placement.height,
                null, // No parent
                null, // No menu
                self.instance,
                null, // No lpParam
            );

            if (new_window == null) {
                debug.debugPrint("Failed to create suggestion window\n", .{});
                return error.WindowCreationFailed;
            }

            self.suggestion_window = new_window;
        } else {
            // Reposition existing window
            _ = api.SetWindowPos(
                self.suggestion_window.?,
                api.HWND_TOPMOST,
                placement.x,
                placement.y,
                placement.width,
                placement.height,
                api.SWP_SHOWWINDOW,
            );
        }

        // Simple show without animation for now
        _ = api.ShowWindow(self.suggestion_window.?, api.SW_SHOWNOACTIVATE);
        _ = api.UpdateWindow(self.suggestion_window.?);
    }

    /// Set current text context
    pub fn setTextContext(self: *AutocompleteUI, full_text: []const u8, current_word: []const u8) void {
        self.current_text = full_text;
        self.current_word = current_word;
    }

    /// Hide the suggestions
    pub fn hideSuggestions(self: *AutocompleteUI) void {
        self.is_visible = false;
        self.current_suggestion = null;

        // Hide the UI window if it exists
        if (self.suggestion_window != null) {
            _ = api.ShowWindow(self.suggestion_window.?, api.SW_HIDE);
        }
    }

    /// Select a suggestion by index
    pub fn selectSuggestion(self: *AutocompleteUI, index: i32) void {
        if (index >= 0 and index < self.suggestions.len) {
            self.selected_index = index;
            window.g_ui_state.selected_index = index;
            self.current_suggestion = self.suggestions[@intCast(index)];

            // Update UI to highlight the selected suggestion
            if (self.suggestion_window != null) {
                _ = api.InvalidateRect(self.suggestion_window.?, null, 1);
                _ = api.UpdateWindow(self.suggestion_window.?);
            }
        }
    }

    /// Clean up resources
    pub fn deinit(self: *AutocompleteUI) void {
        // Clean up window resources
        if (self.suggestion_window != null) {
            _ = api.DestroyWindow(self.suggestion_window.?);
            self.suggestion_window = null;
        }

        // Unregister window class
        if (self.window_class_atom != 0) {
            _ = api.UnregisterClassA(window.SUGGESTION_WINDOW_CLASS, self.instance);
        }
    }
};
