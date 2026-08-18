const std = @import("std");

pub const sysinput = @import("exports.zig");

const buffer = sysinput.core.buffer;
const config = sysinput.core.config;
const dictionary = sysinput.text.dictionary;
const autocomplete = sysinput.text.autocomplete;
const edit_distance = sysinput.text.edit_distance;
const insertion = sysinput.win32.insertion;
const stats = sysinput.suggestion.stats;
const key_decoder = sysinput.input.key_decoder;
const api = sysinput.win32.api;
const candidate_model = sysinput.suggestion.candidate;
const prediction_worker = sysinput.suggestion.worker;

var worker_test_mutex = std.Thread.Mutex{};
var worker_test_learned = false;
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

fn testWorkerLearn(word: []const u8) !void {
    worker_test_mutex.lock();
    defer worker_test_mutex.unlock();
    worker_test_learned = std.mem.eql(u8, word, "accepted");
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

fn testPredictionWorker() !void {
    var request = prediction_worker.PredictionRequest{};
    request.set(42, "hello world", "wor");
    try expect(request.version == 42);
    try expectEqualStrings("hello world", request.textSlice());
    try expectEqualStrings("wor", request.wordSlice());

    worker_test_mutex.lock();
    worker_test_learned = false;
    worker_test_mutex.unlock();
    worker_test_delivered_version = 0;
    worker_test_delivered_word_len = 0;

    try prediction_worker.init(testWorkerCompute, testWorkerDeliver, testWorkerLearn);
    defer prediction_worker.deinit();

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
    };

    try testWordCharacters();
    try testKeyboardEventClassification();
    try testActiveLayoutTranslation();
    try testStructuredCandidates();
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
    try stdout.writeAll("SysInput characterization: 12/12 checks passed\n");
}
