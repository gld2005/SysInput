const std = @import("std");
pub const sysinput = @import("exports.zig");

const keyboard = sysinput.input.keyboard;
const buffer = sysinput.core.buffer;
const buffer_controller = sysinput.core.buffer_controller;
const manager = sysinput.suggestion.manager;
const prediction_worker = sysinput.suggestion.worker;
const win32 = sysinput.win32.hook;
const debug = sysinput.core.debug;
const edit_distance = sysinput.text.edit_distance;
const lifecycle = sysinput.win32.lifecycle;
const data_paths = sysinput.core.data_paths;
const runtime_settings = sysinput.core.runtime_settings;

/// General Purpose Allocator for dynamic memory
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var runtime_store_ptr: ?*runtime_settings.Store = null;

fn setInputEnabled(enabled: bool) bool {
    if (enabled) {
        if (keyboard.g_hook == null) {
            keyboard.g_hook = keyboard.setupKeyboardHook() catch return false;
            buffer_controller.invalidatePhysicalInputState();
        }
        if (runtime_store_ptr) |store| store.setAndSave(.enabled, true) catch |err| {
            debug.debugPrint("Failed to persist enabled setting: {}\n", .{err});
        };
        return true;
    }

    if (keyboard.g_hook) |hook| {
        if (win32.UnhookWindowsHookEx(hook) == 0) return false;
        keyboard.g_hook = null;
    }
    manager.hideSuggestions();
    buffer_controller.invalidatePhysicalInputState();
    if (runtime_store_ptr) |store| store.setAndSave(.enabled, false) catch |err| {
        debug.debugPrint("Failed to persist enabled setting: {}\n", .{err});
    };
    return true;
}

fn setStartupSetting(enabled: bool) void {
    if (runtime_store_ptr) |store| store.setAndSave(.start_with_windows, enabled) catch {};
}

pub fn main() !void {
    // Initialize memory allocator
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const options = lifecycle.Options.parse(args);

    var single_instance = (try lifecycle.SingleInstance.acquire()) orelse return;
    defer single_instance.deinit();

    var paths = try data_paths.DataPaths.init(allocator, options.portable);
    defer paths.deinit();
    const settings_result = try runtime_settings.Store.initAt(allocator, paths.root);
    var runtime_store = settings_result.store;
    defer runtime_store.deinit();
    runtime_store_ptr = &runtime_store;
    defer runtime_store_ptr = null;
    if (settings_result.status != .loaded) runtime_store.save() catch {};

    // Initialize buffer controller
    try buffer_controller.init(allocator);

    // Get module instance for UI initialization
    const hInstance = win32.GetModuleHandleA(null);

    // Initialize suggestion handler
    try manager.init(allocator, hInstance, paths.profiles, &runtime_store);
    defer manager.deinit();

    // Start the bounded prediction worker before the hook begins submitting
    // snapshots. Registered after manager so it is stopped first on shutdown.
    try prediction_worker.init(
        manager.computePrediction,
        manager.applyPrediction,
        manager.recordPredictionFeedback,
        manager.maintainPersonalProfile,
    );
    defer prediction_worker.deinit();

    debug.debugPrint("Starting SysInput...\n", .{});

    // Set up the keyboard hook
    if (runtime_store.isEnabled(.enabled)) {
        keyboard.g_hook = try keyboard.setupKeyboardHook();
        debug.debugPrint("Keyboard hook installed successfully.\n", .{});
    }

    defer {
        if (keyboard.g_hook) |hook| {
            _ = win32.UnhookWindowsHookEx(hook);
            keyboard.g_hook = null;
            debug.debugPrint("Keyboard hook removed.\n", .{});
        }
    }

    try lifecycle.init(
        allocator,
        hInstance,
        options,
        runtime_store.isEnabled(.enabled),
        .{ .set_enabled = setInputEnabled, .startup_changed = setStartupSetting },
    );
    defer lifecycle.deinit();

    // Initial text field detection
    buffer_controller.detectActiveTextField();

    // Run the message loop to keep the hook active
    keyboard.messageLoop() catch |err| {
        std.debug.print("Message loop error: {}\n", .{err});
    };
}

test "basic buffer operations" {
    // TODO: Implement basic buffer operation tests
    // Tests should cover:
    // - Buffer initialization
    // - String insertion
    // - Character insertion
    // - Backspace functionality
    // - Buffer reset
    // - Special character handling
    // - Word extraction
    // - Buffer size limits
}

test "edit distance calculation" {
    // TODO: Implement edit distance calculation tests
    // Tests should cover:
    // - Basic edit distance between similar words
    // - Edit distance with empty strings
    // - Similarity scoring for suggestions
    // - Edge cases for the algorithm
}
