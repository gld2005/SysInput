const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const spellcheck = sysinput.text.spellcheck;
const autocomplete = sysinput.text.autocomplete;
const suggestion_ui = sysinput.ui.suggestion_ui;
const buffer_controller = sysinput.core.buffer_controller;
const debug = sysinput.core.debug;
const position = sysinput.ui.position;
const insertion = sysinput.win32.insertion;
const window_detection = sysinput.input.window_detection;
const stats = sysinput.suggestion.stats;
const config = sysinput.core.config;
const candidate_model = sysinput.suggestion.candidate;
const prediction_worker = sysinput.suggestion.worker;
const personal_profile = sysinput.text.personal_profile;
const context_prediction = sysinput.text.context_prediction;
const text_inject = sysinput.win32.text_inject;

const CandidateTextStorage = struct {
    display: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    insert: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
};

/// Global variables for allocator access
var gpa_allocator: std.mem.Allocator = undefined;

/// Stats instance
var stats_instance = sysinput.suggestion.stats.init();

/// Global spellchecker
pub var spell_checker: spellcheck.SpellChecker = undefined;

/// Global autocompletion engine
pub var autocomplete_engine: autocomplete.AutocompleteEngine = undefined;
pub var context_model: context_prediction.ContextModel = undefined;

/// List for storing word suggestions
pub var suggestions: std.ArrayList([]const u8) = undefined;

/// Structured candidates are the primary internal representation.
pub var autocomplete_candidates: std.ArrayList(candidate_model.Candidate) = undefined;

/// Borrowed display-text adapter retained for the existing UI.
pub var autocomplete_suggestions: std.ArrayList([]const u8) = undefined;
var candidate_text_storage: [config.TEXT.MAX_SUGGESTIONS]CandidateTextStorage = undefined;
var applied_text: [config.TEXT.MAX_BUFFER_SIZE]u8 = undefined;
var applied_text_len: usize = 0;
var applied_word: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
var applied_word_len: usize = 0;
var latest_applied_version: u64 = 0;
var profile_store: personal_profile.ProfileStore = undefined;
var profile_initialized = false;
var context_profile_store: context_prediction.ContextProfileStore = undefined;
var context_profile_initialized = false;
var saved_profile_revision: u64 = 0;
var saved_context_revision: u64 = 0;
var last_profile_save_ms: i64 = 0;

/// Global UI for autocompletion suggestions
pub var autocomplete_ui_manager: suggestion_ui.AutocompleteUI = undefined;

pub fn clearSuggestions() void {
    autocomplete_candidates.clearRetainingCapacity();
    autocomplete_suggestions.clearRetainingCapacity();
}

/// Initialize suggestion handling components
pub fn init(allocator: std.mem.Allocator, module_instance: anytype) !void {
    gpa_allocator = allocator;

    // Initialize spellchecker
    spell_checker = try spellcheck.SpellChecker.init(allocator);

    // Initialize suggestions lists
    suggestions = std.ArrayList([]const u8).init(allocator);
    autocomplete_candidates = std.ArrayList(candidate_model.Candidate).init(allocator);
    autocomplete_suggestions = std.ArrayList([]const u8).init(allocator);
    try autocomplete_candidates.ensureTotalCapacity(config.TEXT.MAX_SUGGESTIONS);
    try autocomplete_suggestions.ensureTotalCapacity(config.TEXT.MAX_SUGGESTIONS);

    // Initialize autocompletion engine
    autocomplete_engine = try autocomplete.AutocompleteEngine.init(allocator, &spell_checker.dictionary);
    context_model = try context_prediction.ContextModel.init(allocator);

    profile_store = try personal_profile.ProfileStore.initDefault(allocator);
    profile_initialized = true;
    profile_store.load(&autocomplete_engine) catch |err| {
        // A damaged or unsupported profile must never prevent input startup.
        debug.debugPrint("Personal profile ignored: {}\n", .{err});
    };
    context_profile_store = try context_prediction.ContextProfileStore.initDefault(allocator);
    context_profile_initialized = true;
    context_profile_store.load(&context_model) catch |err| {
        debug.debugPrint("Context profile ignored: {}\n", .{err});
    };
    saved_profile_revision = autocomplete_engine.revision;
    saved_context_revision = context_model.revision;
    last_profile_save_ms = std.time.milliTimestamp();

    // Initialize UI
    autocomplete_ui_manager = try suggestion_ui.AutocompleteUI.init(allocator, module_instance);

    // Set callback
    autocomplete_ui_manager.setSelectionCallback(handleSuggestionSelection);

    // Reset stats
    stats_instance = sysinput.suggestion.stats.init();
    latest_applied_version = 0;
}

/// Runs only on the prediction worker. The engine and in-memory frequency map
/// are confined to that thread after worker startup.
pub fn computePrediction(
    request: *const prediction_worker.PredictionRequest,
    result: *prediction_worker.PredictionResult,
) !void {
    const target_id: usize = if (request.target_window) |window| @intFromPtr(window) else 0;
    try autocomplete_engine.processTextSnapshot(target_id, request.textSlice());
    try context_model.processTextSnapshot(target_id, request.textSlice());
    autocomplete_engine.setCurrentWord(request.wordSlice());
    defer autocomplete_engine.setCurrentWord("");

    var generated = std.ArrayList([]const u8).init(gpa_allocator);
    defer {
        for (generated.items) |item| gpa_allocator.free(item);
        generated.deinit();
    }
    try autocomplete_engine.getSuggestions(&generated);

    for (generated.items) |text| {
        const info = autocomplete_engine.suggestionInfo(text);
        const source: candidate_model.CandidateSource = if (info.personal)
            .personal_frequency
        else
            .dictionary;
        const confidence: u16 = if (info.personal) 700 else 500;
        var structured = try candidate_model.Candidate.wordCompletion(
            text,
            request.word_len,
            source,
            info.score,
            confidence,
        );
        if (!result.addCandidate(&structured)) break;
    }

    if (request.word_len == 0 and result.candidate_count == 0) {
        const context_predictions = context_model.predict();
        for (context_predictions.slice()) |prediction| {
            const text = prediction.textSlice();
            var structured = try candidate_model.Candidate.init(
                prediction.kind,
                .learned_phrase,
                text,
                text,
                0,
                prediction.score,
                prediction.confidence,
            );
            try structured.addChunk(
                0,
                text.len,
                if (prediction.kind == .next_word) .word else .phrase,
            );
            if (!result.addCandidate(&structured)) break;
        }
    }
}

/// Runs on the worker for accepted-word learning, never in the keyboard hook.
pub fn recordPredictionFeedback(
    feedback_kind: prediction_worker.FeedbackKind,
    candidate_kind: candidate_model.CandidateKind,
    text: []const u8,
) !void {
    switch (candidate_kind) {
        .word_completion => switch (feedback_kind) {
            .shown => try autocomplete_engine.recordShown(text),
            .accepted => try autocomplete_engine.completeWord(text),
        },
        .next_word, .phrase_completion => context_model.recordFeedback(
            if (feedback_kind == .shown) .shown else .accepted,
            text,
        ),
        .sentence_completion => {},
    }
}

/// Runs only on the prediction worker. Regular calls are cheap revision/time
/// checks; shutdown forces the final atomic save.
pub fn maintainPersonalProfile(force: bool) !void {
    const personal_dirty = profile_initialized and autocomplete_engine.revision != saved_profile_revision;
    const context_dirty = context_profile_initialized and context_model.revision != saved_context_revision;
    if (!personal_dirty and !context_dirty) return;
    const now = std.time.milliTimestamp();
    if (!force and now - last_profile_save_ms < 60_000) return;
    if (personal_dirty) {
        try profile_store.save(&autocomplete_engine);
        saved_profile_revision = autocomplete_engine.revision;
    }
    if (context_dirty) {
        try context_profile_store.save(&context_model);
        saved_context_revision = context_model.revision;
    }
    last_profile_save_ms = now;
}

/// Runs on the Windows message thread. It copies the fixed worker result into
/// stable manager storage before passing borrowed display slices to the UI.
pub fn applyPrediction(result: *const prediction_worker.PredictionResult) void {
    if (result.version <= latest_applied_version) return;
    latest_applied_version = result.version;

    // A result must never follow the user into another application while the
    // worker is finishing an older request.
    if (result.target_window != api.GetForegroundWindow()) {
        clearSuggestions();
        hideSuggestions();
        return;
    }

    clearSuggestions();
    applied_text_len = result.text_len;
    applied_word_len = result.word_len;
    @memcpy(applied_text[0..applied_text_len], result.textSlice());
    @memcpy(applied_word[0..applied_word_len], result.wordSlice());

    for (result.candidates[0..result.candidate_count], 0..) |*record, index| {
        const display = record.displaySlice();
        const insert = record.insertSlice();
        @memcpy(candidate_text_storage[index].display[0..display.len], display);
        @memcpy(candidate_text_storage[index].insert[0..insert.len], insert);

        var structured = candidate_model.Candidate.init(
            record.kind,
            record.source,
            candidate_text_storage[index].display[0..display.len],
            candidate_text_storage[index].insert[0..insert.len],
            record.replace_length,
            record.score,
            record.confidence,
        ) catch continue;
        structured.chunk_count = record.chunk_count;
        structured.active_chunk = record.active_chunk;
        @memcpy(structured.chunks[0..record.chunk_count], record.chunks[0..record.chunk_count]);
        if (!structured.isValid()) continue;

        autocomplete_candidates.appendAssumeCapacity(structured);
        autocomplete_suggestions.appendAssumeCapacity(structured.display_text);
    }

    const text = applied_text[0..applied_text_len];
    const word = applied_word[0..applied_word_len];
    const caret = position.getCaretPosition();
    showSuggestions(text, word, caret.x, caret.y) catch |err| {
        debug.debugPrint("Failed to apply worker prediction: {}\n", .{err});
        hideSuggestions();
    };
}

/// Check if a word is spelled correctly
pub fn isWordCorrect(word: []const u8) bool {
    return spell_checker.isCorrect(word);
}

/// Get spelling suggestions for a word
pub fn getSpellingSuggestions(word: []const u8) !void {
    // Clear existing suggestions
    for (suggestions.items) |item| {
        gpa_allocator.free(item);
    }
    suggestions.clearRetainingCapacity();

    // Get suggestions
    try spell_checker.getSuggestions(word, &suggestions);
}

/// Show suggestions in UI
pub fn showSuggestions(current_text: []const u8, current_word: []const u8, x: i32, y: i32) !void {
    debug.debugPrint("Handler showSuggestions called with word '{s}'\n", .{current_word});
    debug.debugPrint("Have {d} structured candidates to display\n", .{autocomplete_candidates.items.len});

    // Print first few suggestions
    for (autocomplete_candidates.items, 0..) |candidate, i| {
        if (i < 5) {
            debug.debugPrint(
                "  Candidate {d}: '{s}' ({s}/{s}, confidence={d})\n",
                .{ i, candidate.display_text, @tagName(candidate.kind), @tagName(candidate.source), candidate.confidence },
            );
        }
    }

    // Use config for minimum word length to show suggestions
    const can_show = autocomplete_candidates.items.len > 0 and
        ((autocomplete_candidates.items[0].kind == .word_completion and
            current_word.len >= config.BEHAVIOR.MIN_TRIGGER_LEN) or
            (autocomplete_candidates.items[0].kind != .word_completion and current_word.len == 0));
    if (can_show) {
        // Only show suggestions if auto-show is enabled
        if (config.BEHAVIOR.AUTO_SHOW_SUGGESTIONS) {
            // Set context
            autocomplete_ui_manager.setTextContext(current_text, current_word);

            // Show suggestions at the specified position
            try autocomplete_ui_manager.showSuggestions(autocomplete_suggestions.items, x, y);

            // Per-word exposure is queued back to the prediction thread. This
            // keeps scoring state single-threaded and enables ignore penalties.
            for (autocomplete_candidates.items) |candidate| {
                prediction_worker.submitShownCandidate(candidate.kind, candidate.insert_text);
            }

            // Update stats
            if (config.STATS.COLLECT_STATS) {
                sysinput.suggestion.stats.recordSuggestionShown(&stats_instance);
            }
        }
    } else {
        debug.debugPrint("No suggestions to show (word len: {d})\n", .{current_word.len});
        hideSuggestions();
    }
}

/// Update the position of suggestions if visible
pub fn updateSuggestionPosition() void {
    if (autocomplete_ui_manager.is_visible) {
        const pos = position.getCaretPosition();
        if (pos.x != 0 or pos.y != 0) {
            // Offset below caret
            autocomplete_ui_manager.updatePosition(pos.x, pos.y + 20);
        }
    }
}

/// Enhanced suggestion word replacement that tries multiple methods
/// Returns true if successful
pub fn replaceSuggestionWord(current_word: []const u8, suggestion: []const u8) bool {
    debug.debugPrint("Replacing word '{s}' with '{s}'\n", .{ current_word, suggestion });

    // Skip if no word to replace
    if (current_word.len == 0) {
        debug.debugPrint("No current word to replace\n", .{});
        return false;
    }

    // Track metrics and timing
    sysinput.suggestion.stats.recordInsertionAttempt(&stats_instance);
    const start_time = std.time.milliTimestamp();

    // Get focus window for class detection
    const focus_hwnd = api.getFocus();
    var success = false;

    // Add this at the top of replaceSuggestionWord function
    if (focus_hwnd != null) {
        // Use direct Windows API call to get raw class name
        var raw_class: [128]u8 = undefined;
        const raw_class_len = api.GetClassNameA(focus_hwnd.?, @ptrCast(&raw_class), 128);

        if (raw_class_len > 0) {
            const class_str = raw_class[0..@intCast(raw_class_len)];
            debug.debugPrint("Raw window class: '{s}' (len: {d})\n", .{ class_str, raw_class_len });

            // Check if it contains "Edit" or "Notepad" case-insensitively
            var is_notepad = false;

            // Check each character in lowercase
            for (0..class_str.len - 3) |i| {
                if (i + 4 <= class_str.len) {
                    const slice = class_str[i .. i + 4];
                    if (std.ascii.eqlIgnoreCase(slice, "edit")) {
                        is_notepad = true;
                        break;
                    }
                }

                if (i + 7 <= class_str.len) {
                    const slice = class_str[i .. i + 7];
                    if (std.ascii.eqlIgnoreCase(slice, "notepad")) {
                        is_notepad = true;
                        break;
                    }
                }
            }

            // For common Windows Notepad class
            if (class_str.len == 5 and std.ascii.eqlIgnoreCase(class_str, "Notepad")) {
                is_notepad = true;
            }

            // Also check for generic Windows text control classes
            if (class_str.len == 4 and std.ascii.eqlIgnoreCase(class_str, "Edit")) {
                is_notepad = true;
            }

            if (is_notepad) {
                debug.debugPrint("*** NOTEPAD DETECTED! ***\n", .{});

                // Now use direct key simulation for Notepad
                debug.debugPrint("Using key simulation for Notepad\n", .{});

                // Set window to foreground to ensure it receives input
                _ = api.setForegroundWindow(focus_hwnd.?);

                // 1. Delete the current word with backspace
                for (0..current_word.len) |_| {
                    // Send backspace character by character
                    var input: api.INPUT = undefined;
                    input.type = api.INPUT_KEYBOARD;
                    input.ki.wVk = api.VK_BACK;
                    input.ki.wScan = 0;
                    input.ki.dwFlags = 0; // Key down
                    input.ki.time = 0;
                    input.ki.dwExtraInfo = 0;
                    _ = api.sendInput(1, &input, @sizeOf(api.INPUT));

                    // Key up
                    input.ki.dwFlags = api.KEYEVENTF_KEYUP;
                    _ = api.sendInput(1, &input, @sizeOf(api.INPUT));

                    api.sleep(5); // Short delay between keys
                }

                // 2. Insert the suggestion character by character
                for (suggestion) |c| {
                    // Send character using unicode method
                    var input: api.INPUT = undefined;
                    input.type = api.INPUT_KEYBOARD;
                    input.ki.wVk = 0;
                    input.ki.wScan = c;
                    input.ki.dwFlags = api.KEYEVENTF_UNICODE;
                    input.ki.time = 0;
                    input.ki.dwExtraInfo = 0;
                    _ = api.sendInput(1, &input, @sizeOf(api.INPUT));

                    // Key up
                    input.ki.dwFlags = api.KEYEVENTF_UNICODE | api.KEYEVENTF_KEYUP;
                    _ = api.sendInput(1, &input, @sizeOf(api.INPUT));

                    api.sleep(5); // Short delay between keys
                }

                // 3. Add a space
                var space_input: api.INPUT = undefined;
                space_input.type = api.INPUT_KEYBOARD;
                space_input.ki.wVk = api.VK_SPACE;
                space_input.ki.wScan = 0;
                space_input.ki.dwFlags = 0;
                space_input.ki.time = 0;
                space_input.ki.dwExtraInfo = 0;
                _ = api.sendInput(1, &space_input, @sizeOf(api.INPUT));

                // Key up
                space_input.ki.dwFlags = api.KEYEVENTF_KEYUP;
                _ = api.sendInput(1, &space_input, @sizeOf(api.INPUT));

                // 4. Update buffer manually
                resyncBufferWithTextField();

                // Add to autocomplete engine
                prediction_worker.submitLearnedWord(suggestion);

                debug.debugPrint("Key simulation completed\n", .{});
                success = true;
                return true;
            } else {
                debug.debugPrint("Not a Notepad/Edit window\n", .{});
            }
        }
    }

    // Fallback to backspace-and-type approach
    if (!success) {
        debug.debugPrint("Using backspace-and-type approach\n", .{});

        // Delete the current word by backspacing
        var i: usize = 0;
        while (i < current_word.len) : (i += 1) {
            buffer_controller.processBackspace() catch |err| {
                debug.debugPrint("Backspace error: {}\n", .{err});
                return false;
            };
        }

        // Insert the suggestion
        buffer_controller.insertString(suggestion) catch |err| {
            debug.debugPrint("Suggestion insertion error: {}\n", .{err});
            return false;
        };

        // Add a space after the suggestion
        buffer_controller.insertString(" ") catch |err| {
            debug.debugPrint("Space insertion error: {}\n", .{err});
        };

        // Add to autocomplete engine
        prediction_worker.submitLearnedWord(suggestion);

        debug.debugPrint("Backspace-and-type approach succeeded\n", .{});
        success = true;
    }

    // Update metrics
    if (success) {
        sysinput.suggestion.stats.recordInsertionSuccess(&stats_instance);
    }

    // Record timing
    const elapsed = std.time.milliTimestamp() - start_time;
    sysinput.suggestion.stats.recordInsertionTime(&stats_instance, @intCast(elapsed));

    debug.debugPrint("Word replacement {s} after {d}ms\n", .{ if (success) "succeeded" else "failed", elapsed });

    return success;
}

fn findCandidateByDisplayText(text: []const u8) ?*const candidate_model.Candidate {
    for (autocomplete_candidates.items) |*candidate| {
        if (std.mem.eql(u8, candidate.display_text, text)) return candidate;
    }
    return null;
}

fn getSelectedCandidate() ?*const candidate_model.Candidate {
    const index = autocomplete_ui_manager.selected_index;
    if (index < 0) return null;
    const item_index: usize = @intCast(index);
    if (item_index >= autocomplete_candidates.items.len) return null;
    return &autocomplete_candidates.items[item_index];
}

/// Handle suggestion selection from the autocomplete UI
pub fn handleSuggestionSelection(suggestion: []const u8) void {
    const candidate = findCandidateByDisplayText(suggestion) orelse {
        debug.debugPrint("No structured candidate for UI selection: '{s}'\n", .{suggestion});
        return;
    };
    if (candidate.kind == .next_word or candidate.kind == .phrase_completion) {
        acceptContextCandidate(candidate);
        return;
    }
    if (candidate.kind != .word_completion) {
        debug.debugPrint("Unsupported candidate kind {s}\n", .{@tagName(candidate.kind)});
        return;
    }

    debug.debugPrint("Handling candidate selection for: '{s}'\n", .{candidate.display_text});

    const current_word = buffer_controller.getCurrentWord() catch {
        debug.debugPrint("Error getting current word\n", .{});
        return;
    };

    // If there's a current word, replace it with the suggestion
    if (current_word.len > 0) {
        debug.debugPrint("Current word: '{s}'\n", .{current_word});

        // Simply call replaceSuggestionWord which contains all the logic
        if (replaceSuggestionWord(current_word, candidate.insert_text)) {
            // Update stats
            sysinput.suggestion.stats.recordSuggestionAccepted(&stats_instance);
        }
    }
}

/// Accept the current suggestion
pub fn acceptCurrentSuggestion() void {
    if (!autocomplete_ui_manager.is_visible) return;

    const candidate = getSelectedCandidate() orelse return;
    if (candidate.kind == .next_word or candidate.kind == .phrase_completion) {
        acceptContextCandidate(candidate);
        return;
    }
    if (candidate.kind != .word_completion) {
        debug.debugPrint("Unsupported candidate kind {s}\n", .{@tagName(candidate.kind)});
        return;
    }
    const suggestion = candidate.insert_text;
    debug.debugPrint(
        "Accepting candidate: '{s}' ({s}/{s})\n",
        .{ candidate.display_text, @tagName(candidate.kind), @tagName(candidate.source) },
    );

    // Get the current word
    const current_word = buffer_controller.getCurrentWord() catch {
        debug.debugPrint("Error getting current word\n", .{});
        return;
    };

    if (current_word.len == 0) {
        debug.debugPrint("No current word to replace\n", .{});
        return;
    }

    if (candidate.replace_length != current_word.len) {
        debug.debugPrint(
            "Candidate replace range changed from {d} to {d}; using live word\n",
            .{ candidate.replace_length, current_word.len },
        );
    }

    debug.debugPrint("Replacing '{s}' with '{s}'\n", .{ current_word, suggestion });

    // Try multiple methods to get the target window
    var target_hwnd: ?api.HWND = null;

    // 1. First try GetFocus to get directly focused control
    target_hwnd = api.getFocus();
    if (target_hwnd != null) {
        debug.debugPrint("Using focused window\n", .{});
    }
    // 2. If that fails, try text_field_manager's active field
    else if (buffer_controller.text_field_manager.has_active_field) {
        target_hwnd = buffer_controller.text_field_manager.active_field.handle;
        debug.debugPrint("Using text field manager's active field\n", .{});
    }
    // 3. Last resort: use foreground window
    else {
        target_hwnd = api.getForegroundWindow();
        debug.debugPrint("Using foreground window\n", .{});
    }

    if (target_hwnd == null) {
        debug.debugPrint("Could not find any target window\n", .{});
        return;
    }

    // Try to ensure window has focus
    _ = api.setForegroundWindow(target_hwnd.?);

    // Get the preferred method for this window class
    const method = window_detection.getPreferredMethodForWindow(target_hwnd.?);
    var success = false;

    // Record insertion attempt
    if (config.STATS.COLLECT_STATS) {
        sysinput.suggestion.stats.recordInsertionAttempt(&stats_instance);
    }
    const start_time = std.time.milliTimestamp();

    // Try the preferred method first
    success = insertion.tryInsertionMethod(target_hwnd.?, current_word, suggestion, method, gpa_allocator);

    // If preferred method failed, try others in fallback order
    if (!success) {
        debug.debugPrint("Preferred method failed, trying fallbacks\n", .{});
        const fallback_methods = [_]u8{
            @intFromEnum(insertion.InsertMethod.Clipboard),
            @intFromEnum(insertion.InsertMethod.KeySimulation),
            @intFromEnum(insertion.InsertMethod.DirectMessage),
        };

        for (fallback_methods) |fallback_method| {
            if (fallback_method == method) continue; // Skip the already-tried method

            success = insertion.tryInsertionMethod(target_hwnd.?, current_word, suggestion, fallback_method, gpa_allocator);
            if (success) break;
        }
    }

    // If any method succeeded
    if (success) {
        // Remember this successful method for this window class
        window_detection.storeSuccessfulMethod(target_hwnd.?, method, gpa_allocator);

        // Wait for the changes to take effect
        api.sleep(config.PERFORMANCE.TEXT_INSERTION_DELAY_MS);

        // Force text field detection
        buffer_controller.detectActiveTextField();

        // Manually update buffer with suggestion + space if configured
        buffer_controller.resetBuffer();
        buffer_controller.insertString(suggestion) catch |err| {
            debug.debugPrint("Failed to update buffer with suggestion: {}\n", .{err});
        };

        // Add space if configured
        if (config.BEHAVIOR.INSERT_SPACE_AFTER_COMPLETION) {
            buffer_controller.insertString(" ") catch |err| {
                debug.debugPrint("Failed to add space to buffer: {}\n", .{err});
            };
        }

        // Add to vocabulary if learning is enabled
        if (config.BEHAVIOR.LEARN_FROM_ACCEPTED) {
            prediction_worker.submitLearnedWord(suggestion);
        }

        // Update stats if enabled
        if (config.STATS.COLLECT_STATS) {
            sysinput.suggestion.stats.recordInsertionSuccess(&stats_instance);
            sysinput.suggestion.stats.recordSuggestionAccepted(&stats_instance);
            sysinput.suggestion.stats.recordMethodSuccess(&stats_instance, method);
        }
    } else {
        debug.debugPrint("All text replacement methods failed\n", .{});
    }

    // Record timing if stats enabled
    if (config.STATS.COLLECT_STATS) {
        const elapsed = std.time.milliTimestamp() - start_time;
        sysinput.suggestion.stats.recordInsertionTime(&stats_instance, @intCast(elapsed));
    }

    // Hide suggestions UI regardless of success
    hideSuggestions();
}

fn acceptContextCandidate(candidate: *const candidate_model.Candidate) void {
    const current_word = buffer_controller.getCurrentWord() catch return;
    if (current_word.len != 0) {
        debug.debugPrint("Context changed before candidate acceptance\n", .{});
        hideSuggestions();
        return;
    }

    const target = api.getFocus() orelse api.getForegroundWindow() orelse {
        hideSuggestions();
        return;
    };
    var payload: [config.TEXT.MAX_SUGGESTION_LEN + 1]u8 = undefined;
    if (candidate.insert_text.len + 1 > payload.len) return;
    @memcpy(payload[0..candidate.insert_text.len], candidate.insert_text);
    payload[candidate.insert_text.len] = ' ';
    const insertion_text = payload[0 .. candidate.insert_text.len + 1];

    sysinput.suggestion.stats.recordInsertionAttempt(&stats_instance);
    if (!text_inject.insertTextAsSelection(target, insertion_text)) {
        debug.debugPrint("Context insertion failed for '{s}'\n", .{candidate.insert_text});
        hideSuggestions();
        return;
    }

    buffer_controller.recordInjectedText(insertion_text) catch {
        buffer_controller.invalidatePhysicalInputState();
    };
    prediction_worker.submitAcceptedCandidate(candidate.kind, candidate.insert_text);
    sysinput.suggestion.stats.recordInsertionSuccess(&stats_instance);
    sysinput.suggestion.stats.recordSuggestionAccepted(&stats_instance);
    hideSuggestions();

    const updated_text = buffer_controller.getCurrentText();
    const updated_word = buffer_controller.getCurrentWord() catch "";
    _ = prediction_worker.submitPrediction(updated_text, updated_word);
}

/// Hide suggestions UI
pub fn hideSuggestions() void {
    autocomplete_ui_manager.hideSuggestions();
}

/// Resync the buffer with the text field after modification
fn resyncBufferWithTextField() void {
    if (!buffer_controller.hasActiveTextField()) {
        return;
    }

    const text = buffer_controller.getActiveFieldText() catch |err| {
        debug.debugPrint("Failed to get updated text: {}\n", .{err});
        return;
    };
    defer gpa_allocator.free(text);

    buffer_controller.resetBuffer();
    buffer_controller.insertString(text) catch |err| {
        debug.debugPrint("Failed to update buffer: {}\n", .{err});
    };
}

/// Check if suggestions UI is visible
pub fn isSuggestionUIVisible() bool {
    return autocomplete_ui_manager.is_visible;
}

/// Navigate to previous suggestion
pub fn navigateToPreviousSuggestion() void {
    if (autocomplete_candidates.items.len == 0) return;
    // Move to previous suggestion
    const new_index = if (autocomplete_ui_manager.selected_index <= 0)
        @as(i32, @intCast(autocomplete_candidates.items.len - 1))
    else
        autocomplete_ui_manager.selected_index - 1;

    autocomplete_ui_manager.selectSuggestion(new_index);
    debug.debugPrint("Selected previous suggestion (index {})\n", .{new_index});
}

/// Navigate to next suggestion
pub fn navigateToNextSuggestion() void {
    if (autocomplete_candidates.items.len == 0) return;
    // Move to next suggestion
    const last_index: i32 = @intCast(autocomplete_candidates.items.len - 1);
    const new_index = if (autocomplete_ui_manager.selected_index >= last_index)
        0
    else
        autocomplete_ui_manager.selected_index + 1;

    autocomplete_ui_manager.selectSuggestion(new_index);
    debug.debugPrint("Selected next suggestion (index {})\n", .{new_index});
}

/// Get selected suggestion index
pub fn getSelectedSuggestionIndex() i32 {
    return autocomplete_ui_manager.selected_index;
}

/// Select a suggestion by index
pub fn selectSuggestion(index: i32) void {
    autocomplete_ui_manager.selectSuggestion(index);
}

/// Get number of available suggestions
pub fn getSuggestionCount() usize {
    return autocomplete_candidates.items.len;
}

/// Deinitialize components
pub fn deinit() void {
    // Free resources
    clearSuggestions();
    suggestions.deinit();
    autocomplete_candidates.deinit();
    autocomplete_suggestions.deinit();

    spell_checker.deinit();
    autocomplete_engine.deinit();
    context_model.deinit();
    if (profile_initialized) {
        profile_store.deinit();
        profile_initialized = false;
    }
    if (context_profile_initialized) {
        context_profile_store.deinit();
        context_profile_initialized = false;
    }
    autocomplete_ui_manager.deinit();
}
