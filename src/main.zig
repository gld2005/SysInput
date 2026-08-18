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
const application_exclusions = sysinput.core.application_exclusions;
const app_guard = sysinput.win32.app_guard;
const settings_window = sysinput.ui.settings_window;
const abbreviation_window = sysinput.ui.abbreviation_window;
const corpus_window = sysinput.ui.corpus_window;

/// General Purpose Allocator for dynamic memory
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var runtime_store_ptr: ?*runtime_settings.Store = null;
var application_allocator: std.mem.Allocator = undefined;
var portable_mode = false;

fn setInputEnabled(enabled: bool) bool {
    if (enabled) {
        if (keyboard.g_hook == null) {
            keyboard.g_hook = keyboard.setupKeyboardHook() catch return false;
            buffer_controller.invalidatePhysicalInputState();
        }
        if (runtime_store_ptr) |store| store.setAndSave(.enabled, true) catch |err| {
            debug.debugPrint("Failed to persist enabled setting: {}\n", .{err});
        };
        lifecycle.syncEnabled(true);
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
    lifecycle.syncEnabled(false);
    return true;
}

fn pauseInput() bool {
    if (keyboard.g_hook) |hook| {
        if (win32.UnhookWindowsHookEx(hook) == 0) return false;
        keyboard.g_hook = null;
    }
    manager.hideSuggestions();
    buffer_controller.invalidatePhysicalInputState();
    return true;
}

fn resumeInput() bool {
    const store = runtime_store_ptr orelse return false;
    if (!store.isEnabled(.enabled)) return false;
    if (keyboard.g_hook == null) {
        keyboard.g_hook = keyboard.setupKeyboardHook() catch return false;
    }
    buffer_controller.invalidatePhysicalInputState();
    return true;
}

fn setStartupSetting(enabled: bool) void {
    if (runtime_store_ptr) |store| store.setAndSave(.start_with_windows, enabled) catch {};
}

fn setStartupFromSettings(enabled: bool) bool {
    lifecycle.setStartupEnabled(application_allocator, enabled, portable_mode) catch return false;
    setStartupSetting(enabled);
    return true;
}

fn settingsChanged() void {
    app_guard.invalidateCache();
    manager.hideSuggestions();
    manager.refreshAppearance();
    buffer_controller.invalidatePhysicalInputState();
}

fn openSettings() void {
    settings_window.show();
}

fn openAbout() void {
    settings_window.showPage(.about);
}

fn addCurrentApplication() bool {
    _ = app_guard.addWindow(lifecycle.lastExternalWindow()) catch return false;
    settingsChanged();
    settings_window.refreshApplications();
    return true;
}

fn excludeWindow(window: ?sysinput.win32.api.HWND) bool {
    _ = app_guard.addWindow(window) catch return false;
    settingsChanged();
    settings_window.refreshApplications();
    return true;
}

pub fn main() !void {
    // Initialize memory allocator
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    application_allocator = allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const options = lifecycle.Options.parse(args);
    if (options.shutdown) {
        if (!lifecycle.requestExistingExit(5000)) return error.ShutdownRequestFailed;
        return;
    }
    portable_mode = options.portable;

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
    const exclusions_result = try application_exclusions.Store.initAt(allocator, paths.root);
    var exclusion_store = exclusions_result.store;
    defer exclusion_store.deinit();
    if (exclusions_result.status != .loaded) exclusion_store.save() catch {};
    app_guard.init(&exclusion_store);
    defer app_guard.deinit();

    // Initialize buffer controller
    try buffer_controller.init(allocator);

    // Get module instance for UI initialization
    const hInstance = win32.GetModuleHandleA(null);

    // Initialize suggestion handler
    try manager.init(allocator, hInstance, paths.profiles, paths.root, paths.corpus, &runtime_store);
    defer manager.deinit();

    try abbreviation_window.init(hInstance, manager.abbreviations());
    defer abbreviation_window.deinit();
    try corpus_window.init(hInstance, manager.corpora());
    defer corpus_window.deinit();

    try settings_window.init(
        allocator,
        hInstance,
        &runtime_store,
        &exclusion_store,
        .{
            .set_enabled = setInputEnabled,
            .set_startup = setStartupFromSettings,
            .settings_changed = settingsChanged,
            .add_current_application = addCurrentApplication,
        },
    );
    defer settings_window.deinit();

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
        .{
            .set_enabled = setInputEnabled,
            .startup_changed = setStartupSetting,
            .open_settings = openSettings,
            .open_about = openAbout,
            .exclude_window = excludeWindow,
            .pause_input = pauseInput,
            .resume_input = resumeInput,
        },
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
