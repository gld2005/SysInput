pub const core = struct {
    pub const buffer = @import("core/buffer.zig");
    pub const config = @import("core/config.zig");
    pub const debug = @import("core/debug.zig");
    pub const buffer_controller = @import("core/buffer_controller.zig");
    pub const data_paths = @import("core/data_paths.zig");
    pub const data_location = @import("core/data_location.zig");
    pub const runtime_settings = @import("core/runtime_settings.zig");
    pub const application_exclusions = @import("core/application_exclusions.zig");
};

pub const input = struct {
    pub const keyboard = @import("input/keyboard.zig");
    pub const key_decoder = @import("input/key_decoder.zig");
    pub const language_gate = @import("input/language_gate.zig");
    pub const text_field = @import("input/text_field.zig");
    pub const window_detection = @import("input/window_detection.zig");
};

pub const suggestion = struct {
    pub const candidate = @import("suggestion/candidate.zig");
    pub const lease = @import("suggestion/lease.zig");
    pub const worker = @import("suggestion/worker.zig");
    pub const manager = @import("suggestion/manager.zig");
    pub const stats = @import("suggestion/stats.zig");
};

pub const text = struct {
    pub const autocomplete = @import("text/autocomplete.zig");
    pub const context_prediction = @import("text/context_prediction.zig");
    pub const dictionary = @import("text/dictionary.zig");
    pub const personal_profile = @import("text/personal_profile.zig");
    pub const sentence_prediction = @import("text/sentence_prediction.zig");
    pub const abbreviation = @import("text/abbreviation.zig");
    pub const corpus = @import("text/corpus.zig");
    pub const edit_distance = @import("text/edit_distance.zig");
    pub const spellcheck = @import("text/spellcheck.zig");
};

pub const ui = struct {
    pub const appearance = @import("ui/appearance.zig");
    pub const position = @import("ui/position.zig");
    pub const suggestion_ui = @import("ui/suggestion_ui.zig");
    pub const window = @import("ui/window.zig");
    pub const settings_window = @import("ui/settings_window.zig");
    pub const abbreviation_window = @import("ui/abbreviation_window.zig");
    pub const corpus_window = @import("ui/corpus_window.zig");
};

pub const win32 = platform.windows;
pub const platform = struct {
    pub const windows = struct {
        pub const api = @import("platform/windows/api.zig");
        pub const hook = @import("platform/windows/hook.zig");
        pub const text_inject = @import("platform/windows/text_inject.zig");
        pub const insertion = @import("platform/windows/insertion.zig");
        pub const lifecycle = @import("platform/windows/lifecycle.zig");
        pub const app_guard = @import("platform/windows/app_guard.zig");
    };
};

// Root-level modules
pub const buffer_controller = @import("core/buffer_controller.zig");
