const std = @import("std");

pub const sysinput = @import("exports.zig");

const buffer = sysinput.core.buffer;
const config = sysinput.core.config;
const dictionary = sysinput.text.dictionary;
const autocomplete = sysinput.text.autocomplete;
const personal_profile = sysinput.text.personal_profile;
const context_prediction = sysinput.text.context_prediction;
const sentence_prediction = sysinput.text.sentence_prediction;
const edit_distance = sysinput.text.edit_distance;
const insertion = sysinput.win32.insertion;
const stats = sysinput.suggestion.stats;
const key_decoder = sysinput.input.key_decoder;
const api = sysinput.win32.api;
const candidate_model = sysinput.suggestion.candidate;
const lease_model = sysinput.suggestion.lease;
const prediction_worker = sysinput.suggestion.worker;
const lifecycle = sysinput.win32.lifecycle;
const keyboard = sysinput.input.keyboard;
const runtime_settings = sysinput.core.runtime_settings;
const data_paths = sysinput.core.data_paths;

var worker_test_mutex = std.Thread.Mutex{};
var worker_test_learned = false;
var worker_test_maintenance_forced = false;
var worker_test_delivered_version: u64 = 0;
var worker_test_delivered_word: [32]u8 = undefined;
var worker_test_delivered_word_len: usize = 0;

fn testWorkerCompute(
    request: *const prediction_worker.PredictionRequest,
    result: *prediction_worker.PredictionResult,
) !void {
    var candidate = try candidate_model.Candidate.wordCompletion(
        "completion",
        request.word_len,
        .dictionary,
        1,
        500,
    );
    if (!result.addCandidate(&candidate)) return error.BaselineTestFailed;
}

fn testWorkerDeliver(result: *const prediction_worker.PredictionResult) void {
    worker_test_delivered_version = result.version;
    const word = result.wordSlice();
    worker_test_delivered_word_len = @min(word.len, worker_test_delivered_word.len);
    @memcpy(worker_test_delivered_word[0..worker_test_delivered_word_len], word[0..worker_test_delivered_word_len]);
}

fn testWorkerLearn(
    kind: prediction_worker.FeedbackKind,
    candidate_kind: candidate_model.CandidateKind,
    word: []const u8,
) !void {
    worker_test_mutex.lock();
    defer worker_test_mutex.unlock();
    worker_test_learned = kind == .accepted and candidate_kind == .word_completion and
        std.mem.eql(u8, word, "accepted");
}

fn testWorkerMaintenance(force: bool) !void {
    if (!force) return;
    worker_test_mutex.lock();
    defer worker_test_mutex.unlock();
    worker_test_maintenance_forced = true;
}

const BaselineTestError = error{BaselineTestFailed};

fn expect(value: bool) BaselineTestError!void {
    if (!value) return error.BaselineTestFailed;
}

fn expectEqualStrings(expected: []const u8, actual: []const u8) BaselineTestError!void {
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("expected '{s}', got '{s}'\n", .{ expected, actual });
        return error.BaselineTestFailed;
    }
}

fn freeSuggestions(allocator: std.mem.Allocator, suggestions: *std.ArrayList([]const u8)) void {
    for (suggestions.items) |item| allocator.free(item);
    suggestions.deinit();
}

fn testTextBuffer(allocator: std.mem.Allocator) !void {
    var text_buffer = buffer.TextBuffer.init(allocator);
    try text_buffer.insertString("hello");
    try expectEqualStrings("hello", text_buffer.getContent());

    try text_buffer.deleteCharBackward();
    try expectEqualStrings("hell", text_buffer.getContent());

    try text_buffer.insertString("p world");
    try expectEqualStrings("hellp world", text_buffer.getContent());
}

fn testCursorWordAndCtrlBackspace(allocator: std.mem.Allocator) !void {
    var text_buffer = buffer.TextBuffer.init(allocator);
    try text_buffer.insertString("alpha brave world");

    text_buffer.setCursorOffset(2);
    try expectEqualStrings("alpha", try text_buffer.getCurrentWord());

    text_buffer.setCursorOffset(text_buffer.length);
    try text_buffer.deleteWordBackward();
    try expectEqualStrings("alpha brave ", text_buffer.getContent());
    try text_buffer.deleteWordBackward();
    try expectEqualStrings("alpha ", text_buffer.getContent());
}

fn testWordCharacters() !void {
    try expect(insertion.isWordChar('a'));
    try expect(insertion.isWordChar('Z'));
    try expect(insertion.isWordChar('7'));
    try expect(insertion.isWordChar('_'));
    try expect(insertion.isWordChar('\''));
    try expect(!insertion.isWordChar('-'));
    try expect(!insertion.isWordChar(' '));
}

fn testKeyboardEventClassification() !void {
    try expect(!key_decoder.isInjected(0));
    try expect(key_decoder.isInjected(api.LLKHF_INJECTED));
    try expect(key_decoder.isInjected(api.LLKHF_LOWER_IL_INJECTED));
    try expect(key_decoder.isModifier(api.VK_LSHIFT));
    try expect(key_decoder.isModifier(api.VK_RCONTROL));
    try expect(!key_decoder.isModifier('A'));

    var modifiers = key_decoder.ModifierState{};
    try expect(modifiers.update(api.VK_LSHIFT, true));
    try expect(modifiers.shift);
    try expect(modifiers.update(api.VK_RSHIFT, true));
    try expect(modifiers.update(api.VK_LSHIFT, false));
    try expect(modifiers.shift);
    try expect(modifiers.update(api.VK_RSHIFT, false));
    try expect(!modifiers.shift);
    try expect(modifiers.update(api.VK_RCONTROL, true));
    try expect(modifiers.ctrl);
    try expect(!modifiers.update('A', true));
}

fn testActiveLayoutTranslation() !void {
    var decoder = key_decoder.KeyboardDecoder{};
    var event = std.mem.zeroes(api.KBDLLHOOKSTRUCT);
    event.vkCode = 'A';
    event.scanCode = 0x1E;

    const plain = decoder.decodeEnglishAscii(&event) orelse return error.BaselineTestFailed;
    try expect(plain == 'a' or plain == 'A');

    _ = decoder.observeModifier(api.VK_LSHIFT, true);
    const shifted = decoder.decodeEnglishAscii(&event) orelse return error.BaselineTestFailed;
    try expect(shifted == 'a' or shifted == 'A');
    try expect(plain != shifted);
}

fn testStructuredCandidates() !void {
    var word = try candidate_model.Candidate.wordCompletion(
        "configuration",
        6,
        .dictionary,
        42,
        1200,
    );
    try expect(word.kind == .word_completion);
    try expect(word.source == .dictionary);
    try expect(word.replace_length == 6);
    try expect(word.confidence == candidate_model.MAX_CONFIDENCE);
    try expect(word.chunk_count == 1);
    try expectEqualStrings("configuration", word.currentChunkText());
    try expect(word.isValid());
    try expect(!word.advanceChunk());
    try expectEqualStrings("", word.remainingText());

    var phrase = try candidate_model.Candidate.init(
        .phrase_completion,
        .learned_phrase,
        "me know if you",
        "me know if you",
        0,
        80,
        850,
    );
    try phrase.addChunk(0, 7, .phrase);
    try phrase.addChunk(7, 7, .phrase);
    try expect(phrase.isValid());
    try expectEqualStrings("me know", phrase.currentChunkText());
    try expect(phrase.advanceChunk());
    try expectEqualStrings(" if you", phrase.currentChunkText());
}

fn testProgressiveCandidateAcceptance() !void {
    var word = try candidate_model.Candidate.wordCompletion(
        "configuration",
        4,
        .dictionary,
        10,
        500,
    );
    try expectEqualStrings("configuration", word.acceptance(.chunk).?.text);
    try expectEqualStrings("configuration", word.acceptance(.word).?.text);

    var phrase = try candidate_model.Candidate.init(
        .phrase_completion,
        .learned_phrase,
        "me know if you",
        "me know if you",
        0,
        20,
        800,
    );
    try phrase.addChunk(0, 7, .phrase);
    try phrase.addChunk(7, 7, .phrase);
    const phrase_chunk = phrase.acceptance(.chunk).?;
    try expectEqualStrings("me know", phrase_chunk.text);
    try expectEqualStrings("if you", phrase.remainingAfter(phrase_chunk));
    const phrase_word = phrase.acceptance(.word).?;
    try expectEqualStrings("me", phrase_word.text);
    try expectEqualStrings("know if you", phrase.remainingAfter(phrase_word));

    const sentence_text = "one two three four five six, seven eight";
    var sentence = try candidate_model.Candidate.init(
        .sentence_completion,
        .repeated_sentence,
        sentence_text,
        sentence_text,
        0,
        30,
        900,
    );
    sentence.chunk_count = candidate_model.buildCompletionChunks(sentence.insert_text, &sentence.chunks);
    try expect(sentence.isValid());
    try expectEqualStrings("one two three four", sentence.acceptance(.chunk).?.text);
    try expectEqualStrings("one", sentence.acceptance(.word).?.text);
    const accepted = sentence.acceptance(.chunk).?;
    const remainder = sentence.remainingAfter(accepted);
    try expectEqualStrings("five six, seven eight", remainder);

    var rebuilt = try candidate_model.Candidate.init(
        .sentence_completion,
        .repeated_sentence,
        remainder,
        remainder,
        0,
        30,
        900,
    );
    rebuilt.chunk_count = candidate_model.buildCompletionChunks(rebuilt.insert_text, &rebuilt.chunks);
    try expect(rebuilt.isValid());
    try expectEqualStrings("five six,", rebuilt.acceptance(.chunk).?.text);
    try expectEqualStrings("five", rebuilt.acceptance(.word).?.text);
}

fn testPredictionWorker() !void {
    var request = prediction_worker.PredictionRequest{};
    request.set(42, "hello world", "wor");
    try expect(request.version == 42);
    try expectEqualStrings("hello world", request.textSlice());
    try expectEqualStrings("wor", request.wordSlice());

    worker_test_mutex.lock();
    worker_test_learned = false;
    worker_test_maintenance_forced = false;
    worker_test_mutex.unlock();
    worker_test_delivered_version = 0;
    worker_test_delivered_word_len = 0;

    try prediction_worker.init(testWorkerCompute, testWorkerDeliver, testWorkerLearn, testWorkerMaintenance);

    _ = prediction_worker.submitPrediction("hello", "hel");

    const submit_count: usize = 10_000;
    var submit_timer = try std.time.Timer.start();
    var latest: u64 = 0;
    for (0..submit_count) |_| {
        latest = prediction_worker.submitPrediction("hello world", "wor");
    }
    const submit_ns = submit_timer.read();
    std.debug.print(
        "Prediction worker hook-submit average: {d:.3} us ({d} submissions)\n",
        .{
            @as(f64, @floatFromInt(submit_ns / submit_count)) / std.time.ns_per_us,
            submit_count,
        },
    );
    prediction_worker.submitLearnedWord("accepted");

    var timer = try std.time.Timer.start();
    while (timer.read() < std.time.ns_per_s) {
        prediction_worker.dispatchReady();

        worker_test_mutex.lock();
        const learned = worker_test_learned;
        worker_test_mutex.unlock();
        if (worker_test_delivered_version == latest and learned) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }

    try expect(worker_test_delivered_version == latest);
    try expectEqualStrings("wor", worker_test_delivered_word[0..worker_test_delivered_word_len]);
    worker_test_mutex.lock();
    const learned = worker_test_learned;
    worker_test_mutex.unlock();
    try expect(learned);
    prediction_worker.deinit();
    worker_test_mutex.lock();
    const maintenance_forced = worker_test_maintenance_forced;
    worker_test_mutex.unlock();
    try expect(maintenance_forced);
}

fn testLifecycleContracts(allocator: std.mem.Allocator) !void {
    const background_args = [_][]const u8{ "SysInput.exe", "--background", "--no-startup-write", "--portable" };
    const options = lifecycle.Options.parse(&background_args);
    try expect(options.background);
    try expect(!options.startup_write);
    try expect(options.portable);

    const command = try lifecycle.startupCommand(allocator, "G:\\SysInput\\SysInput.exe", false);
    defer allocator.free(command);
    try expectEqualStrings("\"G:\\SysInput\\SysInput.exe\" --background", command);
    const portable_command = try lifecycle.startupCommand(allocator, "G:\\SysInput\\SysInput.exe", true);
    defer allocator.free(portable_command);
    try expectEqualStrings("\"G:\\SysInput\\SysInput.exe\" --background --portable", portable_command);

    var first = (try lifecycle.SingleInstance.acquireNamed("Local\\SysInput.BaselineTest.SingleInstance")) orelse
        return error.BaselineTestFailed;
    defer first.deinit();
    const duplicate = try lifecycle.SingleInstance.acquireNamed("Local\\SysInput.BaselineTest.SingleInstance");
    try expect(duplicate == null);
}

fn testSafeSuggestionKeys() !void {
    const plain = key_decoder.ModifierState{};
    const ctrl = key_decoder.ModifierState{ .ctrl = true, .ctrl_mask = 1 };
    const alt = key_decoder.ModifierState{ .alt = true, .alt_mask = 1 };
    const shift = key_decoder.ModifierState{ .shift = true, .shift_mask = 1 };

    try expect(keyboard.suggestionKeyAction(api.VK_ESCAPE, plain, true) == .hide);
    try expect(keyboard.suggestionKeyAction(api.VK_RETURN, plain, true) == .pass);
    try expect(keyboard.suggestionKeyAction(api.VK_TAB, plain, true) == .accept_chunk);
    try expect(keyboard.suggestionKeyAction(api.VK_RIGHT, plain, true) == .pass);
    try expect(keyboard.suggestionKeyAction(api.VK_UP, plain, true) == .pass);
    try expect(keyboard.suggestionKeyAction(api.VK_DOWN, plain, true) == .pass);
    try expect(keyboard.suggestionKeyAction(api.VK_RIGHT, ctrl, true) == .accept_word);
    try expect(keyboard.suggestionKeyAction(api.VK_UP, alt, true) == .previous);
    try expect(keyboard.suggestionKeyAction(api.VK_DOWN, alt, true) == .next);
    try expect(keyboard.suggestionKeyAction(api.VK_TAB, ctrl, true) == .pass);
    try expect(keyboard.suggestionKeyAction(api.VK_RIGHT, shift, true) == .pass);
    try expect(keyboard.suggestionKeyAction(api.VK_RIGHT, plain, false) == .accept_word);
    try expect(keyboard.suggestionKeyAction(api.VK_UP, plain, false) == .previous);
    try expect(keyboard.suggestionKeyAction(api.VK_DOWN, plain, false) == .next);
}

fn phase10TempRoot(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}\\.zig-cache\\phase10-{s}-{d}", .{ cwd, suffix, std.time.nanoTimestamp() });
}

fn testRuntimeSettings(allocator: std.mem.Allocator) !void {
    const defaults = runtime_settings.defaultSnapshot();
    try expect(defaults.enabled and defaults.word_completion and defaults.safe_arrow_mode);
    try expect(!defaults.abbreviation_expansion and !defaults.corpus_prediction);

    const encoded = runtime_settings.encode(runtime_settings.mask(.enabled) | runtime_settings.mask(.phrase_completion));
    const decoded = try runtime_settings.decode(&encoded);
    try expect(decoded & runtime_settings.mask(.enabled) != 0);
    var damaged = encoded;
    damaged[damaged.len - 1] ^= 0xff;
    try expect(runtime_settings.decode(&damaged) == error.InvalidSettings);

    const root = try phase10TempRoot(allocator, "settings");
    defer allocator.free(root);
    defer std.fs.cwd().deleteTree(root) catch {};
    const initialized = try runtime_settings.Store.initAt(allocator, root);
    var store = initialized.store;
    defer store.deinit();
    try expect(initialized.status == .missing);
    try store.setAndSave(.word_completion, false);
    try expect(!store.isEnabled(.word_completion));

    const reloaded_result = try runtime_settings.Store.initAt(allocator, root);
    var reloaded = reloaded_result.store;
    defer reloaded.deinit();
    try expect(reloaded_result.status == .loaded);
    try expect(!reloaded.isEnabled(.word_completion));
    try reloaded.setAndSave(.word_completion, true);
    try expect(reloaded.isEnabled(.word_completion));

    var file = try std.fs.cwd().createFile(reloaded.path, .{ .truncate = true });
    try file.writeAll("corrupt");
    file.close();
    const corrupt_result = try runtime_settings.Store.initAt(allocator, root);
    var fallback = corrupt_result.store;
    defer fallback.deinit();
    try expect(corrupt_result.status == .corrupt);
    try expect(fallback.snapshot().safe_arrow_mode);
}

fn testDataPathsAndMigration(allocator: std.mem.Allocator) !void {
    const root = try phase10TempRoot(allocator, "paths");
    defer allocator.free(root);
    defer std.fs.cwd().deleteTree(root) catch {};
    const executable_dir = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(executable_dir);
    const legacy_dir = try std.fs.path.join(allocator, &.{ executable_dir, "data" });
    defer allocator.free(legacy_dir);
    try std.fs.cwd().makePath(legacy_dir);
    const legacy_profile = try std.fs.path.join(allocator, &.{ legacy_dir, "profile.bin" });
    defer allocator.free(legacy_profile);
    var source = try std.fs.cwd().createFile(legacy_profile, .{ .truncate = true });
    try source.writeAll("profile-data");
    source.close();

    var portable = try data_paths.DataPaths.initFromRoots(allocator, .portable, executable_dir, null);
    defer portable.deinit();
    const migrated = try std.fs.path.join(allocator, &.{ portable.profiles, "profile.bin" });
    defer allocator.free(migrated);
    const migrated_bytes = try std.fs.cwd().readFileAlloc(allocator, migrated, 64);
    defer allocator.free(migrated_bytes);
    try expectEqualStrings("profile-data", migrated_bytes);
    try std.fs.cwd().access(legacy_profile, .{});
    var changed_source = try std.fs.cwd().createFile(legacy_profile, .{ .truncate = true });
    try changed_source.writeAll("new-legacy-data");
    changed_source.close();
    var second_portable = try data_paths.DataPaths.initFromRoots(allocator, .portable, executable_dir, null);
    defer second_portable.deinit();
    const preserved_bytes = try std.fs.cwd().readFileAlloc(allocator, migrated, 64);
    defer allocator.free(preserved_bytes);
    try expectEqualStrings("profile-data", preserved_bytes);

    const local_app_data = try std.fs.path.join(allocator, &.{ root, "local" });
    defer allocator.free(local_app_data);
    var standard = try data_paths.DataPaths.initFromRoots(allocator, .standard, executable_dir, local_app_data);
    defer standard.deinit();
    const expected_root = try std.fs.path.join(allocator, &.{ local_app_data, "SysInput" });
    defer allocator.free(expected_root);
    try expectEqualStrings(expected_root, standard.root);
}

fn testLearningCanBeDisabled(allocator: std.mem.Allocator) !void {
    var dict = try dictionary.Dictionary.init(allocator);
    defer dict.deinit();
    var engine = try autocomplete.AutocompleteEngine.init(allocator, &dict);
    defer engine.deinit();
    try engine.processTextSnapshotWithLearning(900, "hello", false);
    try engine.processTextSnapshotWithLearning(900, "hello ", false);
    try expect(engine.recordCount() == 0);
    try expect(engine.revision == 0);

    var context = try context_prediction.ContextModel.init(allocator);
    defer context.deinit();
    const transition_count = context.transitionCount();
    try context.processTextSnapshotWithLearning(901, "alpha beta gamma ", false);
    try expect(context.transitionCount() == transition_count);
    try expect(context.revision == 0);

    var sentence = sentence_prediction.SentenceModel.init(allocator);
    defer sentence.deinit();
    const sentence_count = sentence.recordCount();
    try sentence.processTextSnapshotWithLearning(902, "alpha beta gamma", false);
    try sentence.processTextSnapshotWithLearning(902, "alpha beta gamma.", false);
    try expect(sentence.recordCount() == sentence_count);
    try expect(sentence.revision == 0);
}

fn testCandidateLease() !void {
    var lease = lease_model.Lease{};
    try expect(!lease.matches(1, 10, 20, 30, true, 40, 50));
    lease.bind(7, 10, 20, 30, true, 40, 50);
    try expect(lease.matches(7, 10, 20, 30, true, 40, 50));
    try expect(!lease.matches(8, 10, 20, 30, true, 40, 50));
    try expect(!lease.matches(7, 11, 20, 30, true, 40, 50));
    try expect(!lease.matches(7, 10, 21, 30, true, 40, 50));
    try expect(!lease.matches(7, 10, 20, 31, true, 40, 50));
    try expect(!lease.matches(7, 10, 20, 30, false, 40, 50));
    try expect(!lease.matches(7, 10, 20, 30, true, 41, 50));
    try expect(!lease.matches(7, 10, 20, 30, true, 40, 51));
    lease.invalidate();
    try expect(!lease.matches(7, 10, 20, 30, true, 40, 50));

    lease.bind(8, 10, 20, 30, false, 0, 0);
    try expect(lease.matches(8, 10, 20, 30, false, 999, 999));
}

fn testEditDistance() !void {
    try expect(edit_distance.enhancedEditDistance("test", "test") == 0);
    // Characterize the current early-exit behavior. Although the implementation
    // contains a transposition branch, the quick prefix check returns 3 first.
    try expect(edit_distance.enhancedEditDistance("teh", "the") == 3);
    try expect(edit_distance.calculateSuggestionScore("conf", "configuration") > 0);
    try expect(edit_distance.calculateSuggestionScore("conf", "banana") < 0);
    try expect(@abs(edit_distance.wordSimilarityPercent("same", "same") - 100.0) < 0.001);
}

fn testStatistics() !void {
    var current = stats.init();
    stats.recordSuggestionShown(&current);
    stats.recordSuggestionShown(&current);
    stats.recordSuggestionAccepted(&current);
    stats.recordInsertionAttempt(&current);
    stats.recordInsertionAttempt(&current);
    stats.recordInsertionSuccess(&current);
    stats.recordInsertionTime(&current, 12);

    try expect(current.total_shown == 2);
    try expect(current.accepted == 1);
    try expect(@abs(stats.getInsertionSuccessRate(current) - 50.0) < 0.001);
    try expect(@abs(current.average_insertion_time_ms - 12.0) < 0.001);
}

fn testDictionary(allocator: std.mem.Allocator) !void {
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();

    try expect(words.word_map.count() > 1000);
    try expect(words.contains("the"));
    try expect(words.contains("THE"));
    try expect(words.rankOf("the").? < words.rankOf("configuration").?);
    const range = words.prefixRange("conf");
    try expect(range.end > range.start);
    for (words.ranked_words.items[range.start..range.end]) |entry| {
        try expect(std.mem.startsWith(u8, entry.text, "conf"));
    }
}

fn testPersonalFrequency(allocator: std.mem.Allocator) !void {
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();

    var engine = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer engine.deinit();

    try engine.addWord("codexbaseline");
    try engine.addWord("codexbaseline");
    try engine.addWord("codexbaseline");
    engine.setCurrentWord("codex");

    var suggestions = std.ArrayList([]const u8).init(allocator);
    defer freeSuggestions(allocator, &suggestions);
    try engine.getSuggestions(&suggestions);

    try expect(suggestions.items.len > 0);
    try expectEqualStrings("codexbaseline", suggestions.items[0]);
    try expect(suggestions.items.len <= config.TEXT.MAX_SUGGESTIONS);
}

fn testAutocompleteCacheOwnership(allocator: std.mem.Allocator) !void {
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();

    var engine = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer engine.deinit();

    var suggestions = std.ArrayList([]const u8).init(allocator);
    defer freeSuggestions(allocator, &suggestions);

    engine.setCurrentWord("pre");
    try engine.getSuggestions(&suggestions);
    try expect(suggestions.items.len > 0);

    // The second call frees the first result set before reading the cache. The
    // cache must therefore own its bytes instead of borrowing those slices.
    try engine.getSuggestions(&suggestions);
    try expect(suggestions.items.len > 0);
    for (suggestions.items) |text| try expect(std.mem.startsWith(u8, text, "pre"));
}

fn testDeterministicRanking(allocator: std.mem.Allocator) !void {
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();
    var engine = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer engine.deinit();
    var first = std.ArrayList([]const u8).init(allocator);
    defer freeSuggestions(allocator, &first);
    var second = std.ArrayList([]const u8).init(allocator);
    defer freeSuggestions(allocator, &second);

    engine.setCurrentWord("con");
    try engine.getSuggestions(&first);
    try engine.getSuggestions(&second);
    try expect(first.items.len == second.items.len);
    for (first.items, second.items) |left, right| try expectEqualStrings(left, right);
}

fn testSnapshotLearnsOnce(allocator: std.mem.Allocator) !void {
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();
    var engine = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer engine.deinit();

    try engine.processTextSnapshot(1, "hello");
    try engine.processTextSnapshot(1, "hello ");
    try engine.processTextSnapshot(1, "hello ");
    const stats_for_word = engine.personal_words.get("hello") orelse return error.BaselineTestFailed;
    try expect(stats_for_word.typed_count == 1);
}

fn testProfileRoundTripAndCorruption(allocator: std.mem.Allocator) !void {
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();
    var source = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer source.deinit();
    try source.recordTyped("codexpersisted");
    try source.recordAccepted("codexpersisted");
    try source.recordShown("codexpersisted");

    const bytes = try personal_profile.encode(allocator, &source);
    defer allocator.free(bytes);
    var restored = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer restored.deinit();
    try personal_profile.decodeInto(&restored, bytes);
    const restored_stats = restored.personal_words.get("codexpersisted") orelse return error.BaselineTestFailed;
    try expect(restored_stats.typed_count == 1);
    try expect(restored_stats.accepted_count == 1);
    try expect(restored_stats.shown_count == 1);

    const damaged = try allocator.dupe(u8, bytes);
    defer allocator.free(damaged);
    damaged[damaged.len - 1] ^= 0xff;
    var rejected = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer rejected.deinit();
    try expect(personal_profile.decodeInto(&rejected, damaged) == error.InvalidProfile);
    try expect(rejected.recordCount() == 0);
}

fn testPersonalVocabularyBound(allocator: std.mem.Allocator) !void {
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();
    var engine = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer engine.deinit();
    var storage: [32]u8 = undefined;
    for (0..config.BEHAVIOR.MAX_USER_WORDS + 1) |index| {
        const word = try std.fmt.bufPrint(&storage, "personalword{d}", .{index});
        try engine.recordTyped(word);
    }
    try expect(engine.recordCount() == config.BEHAVIOR.MAX_USER_WORDS);
    try expect(engine.personal_words.get("personalword0") == null);
    try expect(engine.personal_words.get("personalword10000") != null);
}

fn feedContextSequence(
    model: *context_prediction.ContextModel,
    target: usize,
    sequence: []const u8,
) !void {
    var snapshot_storage: [256]u8 = undefined;
    try expect(sequence.len <= snapshot_storage.len);
    for (sequence, 0..) |character, index| {
        snapshot_storage[index] = character;
        try model.processTextSnapshot(target, snapshot_storage[0 .. index + 1]);
    }
}

fn testSeededContextPhrase(allocator: std.mem.Allocator) !void {
    var model = try context_prediction.ContextModel.init(allocator);
    defer model.deinit();
    try model.processTextSnapshot(101, "please let ");
    const predictions = model.predict();
    try expect(predictions.count > 0);
    try expect(predictions.items[0].kind == .phrase_completion);
    try expect(std.mem.startsWith(u8, predictions.items[0].textSlice(), "me know"));
    try expect(predictions.items[0].confidence >= 850);
    for (0..18) |_| model.recordFeedback(.shown, predictions.items[0].textSlice());
    try expect(model.predict().count == 0);
}

fn testContextPartialPhraseFeedback(allocator: std.mem.Allocator) !void {
    var model = try context_prediction.ContextModel.init(allocator);
    defer model.deinit();
    try model.processTextSnapshot(102, "please let ");
    const predictions = model.predict();
    try expect(predictions.count > 0);
    try expect(predictions.items[0].kind == .phrase_completion);
    const revision = model.revision;
    model.recordFeedback(.accepted, "me");
    try expect(model.revision == revision +% 1);
}

fn testLearnedNextWordAndFeedback(allocator: std.mem.Allocator) !void {
    var model = try context_prediction.ContextModel.init(allocator);
    defer model.deinit();
    try feedContextSequence(&model, 201, "alpha beta gamma ");
    try model.processTextSnapshot(202, "alpha beta ");
    const before = model.predict();
    try expect(before.count == 1);
    try expect(before.items[0].kind == .next_word);
    try expectEqualStrings("gamma", before.items[0].textSlice());
    const score_before = before.items[0].score;
    model.recordFeedback(.accepted, "gamma");
    const after = model.predict();
    try expect(after.items[0].score > score_before);
    try expect(model.transitionCount() <= context_prediction.MAX_CONTEXT_TRANSITIONS);
}

fn testLowConfidenceContextStaysHidden(allocator: std.mem.Allocator) !void {
    var model = try context_prediction.ContextModel.init(allocator);
    defer model.deinit();
    try feedContextSequence(&model, 301, "alpha beta gamma ");
    try feedContextSequence(&model, 302, "alpha beta gamma ");
    try feedContextSequence(&model, 303, "alpha beta delta ");
    try feedContextSequence(&model, 304, "alpha beta delta ");
    try model.processTextSnapshot(305, "alpha beta ");
    const predictions = model.predict();
    try expect(predictions.count == 0);
}

fn testContextProfileRoundTrip(allocator: std.mem.Allocator) !void {
    var source = try context_prediction.ContextModel.init(allocator);
    defer source.deinit();
    try feedContextSequence(&source, 401, "alpha beta gamma ");
    try source.processTextSnapshot(402, "alpha beta ");
    source.recordFeedback(.accepted, "gamma");
    const bytes = try context_prediction.encodeProfile(allocator, &source);
    defer allocator.free(bytes);

    var restored = try context_prediction.ContextModel.init(allocator);
    defer restored.deinit();
    try context_prediction.decodeProfileInto(&restored, bytes);
    try restored.processTextSnapshot(403, "alpha beta ");
    const predictions = restored.predict();
    try expect(predictions.count == 1);
    try expectEqualStrings("gamma", predictions.items[0].textSlice());

    const damaged = try allocator.dupe(u8, bytes);
    defer allocator.free(damaged);
    damaged[damaged.len - 1] ^= 0xff;
    var rejected = try context_prediction.ContextModel.init(allocator);
    defer rejected.deinit();
    try expect(context_prediction.decodeProfileInto(&rejected, damaged) == error.InvalidContextProfile);
}

fn feedSentenceSequence(
    model: *sentence_prediction.SentenceModel,
    target: usize,
    sequence: []const u8,
) !void {
    var snapshot_storage: [512]u8 = undefined;
    try expect(sequence.len <= snapshot_storage.len);
    for (sequence, 0..) |character, index| {
        snapshot_storage[index] = character;
        try model.processTextSnapshot(target, snapshot_storage[0 .. index + 1]);
    }
}

fn countWords(text: []const u8) usize {
    var count: usize = 0;
    var in_word = false;
    for (text) |character| {
        if (insertion.isWordChar(character)) {
            if (!in_word) count += 1;
            in_word = true;
        } else {
            in_word = false;
        }
    }
    return count;
}

fn testRepeatedSentenceThresholdAndIgnore(allocator: std.mem.Allocator) !void {
    var model = sentence_prediction.SentenceModel.init(allocator);
    defer model.deinit();
    try feedSentenceSequence(&model, 501, "I hope you meet Alice tomorrow.");
    try model.processTextSnapshot(502, "i hope you ");
    try expect(model.predict().count == 0);

    try feedSentenceSequence(&model, 503, "i hope you meet Alice tomorrow!");
    try model.processTextSnapshot(504, "i hope you ");
    const predictions = model.predict();
    try expect(predictions.count == 1);
    try expectEqualStrings("meet Alice tomorrow", predictions.items[0].textSlice());
    try expect(predictions.items[0].chunk_count == 1);
    try expect(predictions.items[0].chunks[0].kind == .phrase);
    for (0..6) |_| model.recordFeedback(.shown, predictions.items[0].textSlice());
    try expect(model.predict().count == 0);
}

fn testSentencePartialAcceptanceFeedback(allocator: std.mem.Allocator) !void {
    var model = sentence_prediction.SentenceModel.init(allocator);
    defer model.deinit();
    try feedSentenceSequence(&model, 505, "I hope you meet Alice tomorrow.");
    try feedSentenceSequence(&model, 506, "i hope you meet Alice tomorrow!");
    try model.processTextSnapshot(507, "i hope you ");
    const before = model.predict();
    try expect(before.count == 1);
    const revision = model.revision;
    model.recordFeedback(.accepted, "meet");
    try expect(model.revision == revision +% 1);
    const after = model.predict();
    try expect(after.count == 1);
    try expect(after.items[0].score > before.items[0].score);

    const accepted_revision = model.revision;
    model.recordFeedback(.accepted, "mee");
    try expect(model.revision == accepted_revision);
}

fn testSentencePredictionLimitAndChunks(allocator: std.mem.Allocator) !void {
    const sentence = "one two three four five six, seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen.";
    var model = sentence_prediction.SentenceModel.init(allocator);
    defer model.deinit();
    try feedSentenceSequence(&model, 511, sentence);
    try feedSentenceSequence(&model, 512, sentence);
    try model.processTextSnapshot(513, "one two three ");
    const predictions = model.predict();
    try expect(predictions.count == 1);
    const prediction = predictions.items[0];
    try expect(countWords(prediction.textSlice()) == sentence_prediction.MAX_PREDICTED_WORDS);
    try expect(prediction.chunk_count >= 3);
    var expected_start: usize = 0;
    for (prediction.chunks[0..prediction.chunk_count]) |chunk| {
        try expect(chunk.start == expected_start);
        const chunk_text = prediction.textSlice()[chunk.start..chunk.end()];
        try expect(countWords(chunk_text) >= 1);
        try expect(countWords(chunk_text) <= 4);
        expected_start = chunk.end();
    }
    try expect(expected_start == prediction.textSlice().len);
    const comma = std.mem.indexOfScalar(u8, prediction.textSlice(), ',') orelse return error.BaselineTestFailed;
    var punctuation_boundary = false;
    for (prediction.chunks[0..prediction.chunk_count]) |chunk| {
        if (chunk.end() == comma + 1) punctuation_boundary = true;
    }
    try expect(punctuation_boundary);
}

fn testSentenceProfileRoundTrip(allocator: std.mem.Allocator) !void {
    var source = sentence_prediction.SentenceModel.init(allocator);
    defer source.deinit();
    try feedSentenceSequence(&source, 521, "we can review the final report tomorrow.");
    try feedSentenceSequence(&source, 522, "We can review the final report tomorrow!");
    const bytes = try sentence_prediction.encodeProfile(allocator, &source);
    defer allocator.free(bytes);

    var restored = sentence_prediction.SentenceModel.init(allocator);
    defer restored.deinit();
    try sentence_prediction.decodeProfileInto(&restored, bytes);
    try restored.processTextSnapshot(523, "we can review ");
    const predictions = restored.predict();
    try expect(predictions.count == 1);
    try expectEqualStrings("the final report tomorrow", predictions.items[0].textSlice());

    const damaged = try allocator.dupe(u8, bytes);
    defer allocator.free(damaged);
    damaged[damaged.len - 1] ^= 0xff;
    var rejected = sentence_prediction.SentenceModel.init(allocator);
    defer rejected.deinit();
    try expect(sentence_prediction.decodeProfileInto(&rejected, damaged) == error.InvalidSentenceProfile);
}

fn testSentenceRecordBound(allocator: std.mem.Allocator) !void {
    var model = sentence_prediction.SentenceModel.init(allocator);
    defer model.deinit();
    var sentence_storage: [64]u8 = undefined;
    for (0..sentence_prediction.MAX_SENTENCE_RECORDS + 1) |index| {
        const sentence = try std.fmt.bufPrint(&sentence_storage, "alpha beta unique{d}.", .{index});
        try feedSentenceSequence(&model, 600 + index, sentence);
    }
    try expect(model.recordCount() == sentence_prediction.MAX_SENTENCE_RECORDS);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cases = [_]struct {
        name: []const u8,
        run: *const fn (std.mem.Allocator) anyerror!void,
    }{
        .{ .name = "text buffer insertion and backspace", .run = testTextBuffer },
        .{ .name = "cursor word and Ctrl+Backspace", .run = testCursorWordAndCtrlBackspace },
        .{ .name = "bundled dictionary", .run = testDictionary },
        .{ .name = "personal frequency priority", .run = testPersonalFrequency },
        .{ .name = "autocomplete cache ownership", .run = testAutocompleteCacheOwnership },
        .{ .name = "deterministic ranking", .run = testDeterministicRanking },
        .{ .name = "snapshot learns once", .run = testSnapshotLearnsOnce },
        .{ .name = "profile round trip and corrupt fallback", .run = testProfileRoundTripAndCorruption },
        .{ .name = "personal vocabulary bound", .run = testPersonalVocabularyBound },
        .{ .name = "seeded context phrase", .run = testSeededContextPhrase },
        .{ .name = "context partial phrase feedback", .run = testContextPartialPhraseFeedback },
        .{ .name = "learned next word and feedback", .run = testLearnedNextWordAndFeedback },
        .{ .name = "low-confidence context suppression", .run = testLowConfidenceContextStaysHidden },
        .{ .name = "context profile round trip", .run = testContextProfileRoundTrip },
        .{ .name = "repeated sentence threshold and ignore", .run = testRepeatedSentenceThresholdAndIgnore },
        .{ .name = "sentence partial acceptance feedback", .run = testSentencePartialAcceptanceFeedback },
        .{ .name = "sentence prediction limit and chunks", .run = testSentencePredictionLimitAndChunks },
        .{ .name = "sentence profile round trip", .run = testSentenceProfileRoundTrip },
        .{ .name = "sentence record bound", .run = testSentenceRecordBound },
        .{ .name = "lifecycle and startup contracts", .run = testLifecycleContracts },
        .{ .name = "runtime settings persistence and fallback", .run = testRuntimeSettings },
        .{ .name = "data paths and non-destructive migration", .run = testDataPathsAndMigration },
        .{ .name = "personal learning can be disabled", .run = testLearningCanBeDisabled },
    };

    try testWordCharacters();
    try testKeyboardEventClassification();
    try testActiveLayoutTranslation();
    try testStructuredCandidates();
    try testProgressiveCandidateAcceptance();
    try testSafeSuggestionKeys();
    try testCandidateLease();
    try testPredictionWorker();
    try testEditDistance();
    try testStatistics();

    for (cases) |case| {
        case.run(allocator) catch |err| {
            std.debug.print("FAIL: {s}: {}\n", .{ case.name, err });
            return err;
        };
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("SysInput characterization: 33/33 checks passed\n");
}
