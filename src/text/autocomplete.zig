const std = @import("std");
const sysinput = @import("root").sysinput;

const dict = sysinput.text.dictionary;
const insertion = sysinput.win32.insertion;
const config = sysinput.core.config;

const MAX_SUGGESTIONS = config.TEXT.MAX_SUGGESTIONS;

pub const PersonalStats = struct {
    typed_count: u32 = 0,
    shown_count: u32 = 0,
    accepted_count: u32 = 0,
    last_used: u64 = 0,
    last_accepted: u64 = 0,
    consecutive_ignores: u16 = 0,
};

pub const PersonalRecord = struct {
    word: []const u8,
    stats: PersonalStats,
};

pub const SuggestionInfo = struct {
    personal: bool,
    score: i32,
};

const ScoredWord = struct {
    word: []const u8,
    score: i32,
    personal: bool,
};

pub const AutocompleteEngine = struct {
    dictionary: *dict.Dictionary,
    personal_words: std.StringHashMap(PersonalStats),
    personal_order: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    current_word: []const u8,
    usage_clock: u64,
    revision: u64,
    snapshot_target: usize,
    snapshot: [config.TEXT.MAX_BUFFER_SIZE]u8,
    snapshot_len: usize,

    pub fn init(allocator: std.mem.Allocator, dictionary: *dict.Dictionary) !AutocompleteEngine {
        return .{
            .dictionary = dictionary,
            .personal_words = std.StringHashMap(PersonalStats).init(allocator),
            .personal_order = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
            .current_word = "",
            .usage_clock = 0,
            .revision = 0,
            .snapshot_target = 0,
            .snapshot = undefined,
            .snapshot_len = 0,
        };
    }

    pub fn deinit(self: *AutocompleteEngine) void {
        for (self.personal_order.items) |word| self.allocator.free(word);
        self.personal_order.deinit();
        self.personal_words.deinit();
    }

    pub fn setCurrentWord(self: *AutocompleteEngine, word: []const u8) void {
        self.current_word = word;
    }

    /// Compatibility entry point used by baseline tests: a directly observed
    /// completed word counts as typed once.
    pub fn addWord(self: *AutocompleteEngine, word: []const u8) !void {
        try self.recordTyped(word);
    }

    pub fn completeWord(self: *AutocompleteEngine, word: []const u8) !void {
        try self.recordAccepted(word);
        self.current_word = "";
    }

    pub fn recordTyped(self: *AutocompleteEngine, word: []const u8) !void {
        var normalized: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const lower = normalizeWord(word, &normalized) orelse return;
        var stats = try self.ensurePersonal(lower);
        self.tick();
        stats.typed_count +|= 1;
        stats.last_used = self.usage_clock;
        try self.personal_words.put(lower, stats);
        self.revision +%= 1;
    }

    pub fn recordShown(self: *AutocompleteEngine, word: []const u8) !void {
        var normalized: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const lower = normalizeWord(word, &normalized) orelse return;
        const existing = self.personal_words.get(lower) orelse return;
        var updated = existing;
        updated.shown_count +|= 1;
        updated.consecutive_ignores +|= 1;
        try self.personal_words.put(lower, updated);
        self.revision +%= 1;
    }

    pub fn recordAccepted(self: *AutocompleteEngine, word: []const u8) !void {
        var normalized: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const lower = normalizeWord(word, &normalized) orelse return;
        var stats = try self.ensurePersonal(lower);
        self.tick();
        stats.accepted_count +|= 1;
        stats.last_used = self.usage_clock;
        stats.last_accepted = self.usage_clock;
        stats.consecutive_ignores = 0;
        try self.personal_words.put(lower, stats);
        self.revision +%= 1;
    }

    /// Learns only words completed in an appended portion of the same target
    /// snapshot. Re-running prediction for an unchanged buffer learns nothing.
    /// The snapshot is process-local and is never serialized.
    pub fn processTextSnapshot(self: *AutocompleteEngine, target: usize, text: []const u8) !void {
        const bounded = text[0..@min(text.len, self.snapshot.len)];
        const is_append = target != 0 and target == self.snapshot_target and
            bounded.len >= self.snapshot_len and
            std.mem.eql(u8, bounded[0..self.snapshot_len], self.snapshot[0..self.snapshot_len]);

        if (is_append) {
            var start = self.snapshot_len;
            while (start > 0 and insertion.isWordChar(bounded[start - 1])) start -= 1;
            var word_start: ?usize = null;
            for (bounded[start..], start..) |character, index| {
                if (insertion.isWordChar(character)) {
                    if (word_start == null) word_start = index;
                } else if (word_start) |word_index| {
                    if (index >= self.snapshot_len) try self.recordTyped(bounded[word_index..index]);
                    word_start = null;
                }
            }
        }
        @memcpy(self.snapshot[0..bounded.len], bounded);
        self.snapshot_len = bounded.len;
        self.snapshot_target = target;
    }

    pub fn getSuggestions(self: *AutocompleteEngine, results: *std.ArrayList([]const u8)) !void {
        for (results.items) |item| self.allocator.free(item);
        results.clearRetainingCapacity();
        if (self.current_word.len < config.BEHAVIOR.MIN_TRIGGER_LEN) return;

        var normalized: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const prefix = normalizeWord(self.current_word, &normalized) orelse return;
        var top = std.BoundedArray(ScoredWord, MAX_SUGGESTIONS).init(0) catch unreachable;

        const personal_range = personalPrefixRange(self.personal_order.items, prefix);
        for (self.personal_order.items[personal_range.start..personal_range.end]) |word| {
            if (std.mem.eql(u8, word, prefix)) continue;
            const stats = self.personal_words.get(word).?;
            insertTop(&top, .{
                .word = word,
                .score = personalScore(self.usage_clock, word, stats, self.dictionary.rankOf(word)) +
                    caseMatchBonus(self.current_word),
                .personal = true,
            });
        }

        const dictionary_range = self.dictionary.prefixRange(prefix);
        for (self.dictionary.ranked_words.items[dictionary_range.start..dictionary_range.end]) |entry| {
            if (std.mem.eql(u8, entry.text, prefix) or self.personal_words.contains(entry.text)) continue;
            insertTop(&top, .{
                .word = entry.text,
                .score = dictionaryScore(entry.rank, entry.text) + caseMatchBonus(self.current_word),
                .personal = false,
            });
        }

        for (top.slice()) |entry| {
            const output = try self.allocator.dupe(u8, entry.word);
            errdefer self.allocator.free(output);
            if (self.current_word.len != 0 and std.ascii.isUpper(self.current_word[0])) {
                output[0] = std.ascii.toUpper(output[0]);
            }
            try results.append(output);
        }
    }

    pub fn suggestionInfo(self: *const AutocompleteEngine, word: []const u8) SuggestionInfo {
        var normalized: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const lower = normalizeWord(word, &normalized) orelse return .{ .personal = false, .score = 0 };
        if (self.personal_words.get(lower)) |stats| {
            return .{
                .personal = true,
                .score = personalScore(self.usage_clock, lower, stats, self.dictionary.rankOf(lower)) +
                    caseMatchBonus(self.current_word),
            };
        }
        const rank = self.dictionary.rankOf(lower) orelse return .{ .personal = false, .score = 0 };
        return .{
            .personal = false,
            .score = dictionaryScore(rank, lower) + caseMatchBonus(self.current_word),
        };
    }

    pub fn recordCount(self: *const AutocompleteEngine) usize {
        return self.personal_order.items.len;
    }

    pub fn recordAt(self: *const AutocompleteEngine, index: usize) PersonalRecord {
        const word = self.personal_order.items[index];
        return .{ .word = word, .stats = self.personal_words.get(word).? };
    }

    pub fn restoreRecord(self: *AutocompleteEngine, word: []const u8, stats: PersonalStats) !void {
        var normalized: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const lower = normalizeWord(word, &normalized) orelse return;
        _ = try self.ensurePersonal(lower);
        try self.personal_words.put(lower, stats);
        self.usage_clock = @max(self.usage_clock, @max(stats.last_used, stats.last_accepted));
    }

    fn tick(self: *AutocompleteEngine) void {
        self.usage_clock +%= 1;
        if (self.usage_clock == 0) self.usage_clock = 1;
    }

    fn ensurePersonal(self: *AutocompleteEngine, lower: []const u8) !PersonalStats {
        if (self.personal_words.get(lower)) |existing| return existing;
        if (self.personal_order.items.len >= config.BEHAVIOR.MAX_USER_WORDS) self.evictWeakest();
        const owned = try self.allocator.dupe(u8, lower);
        errdefer self.allocator.free(owned);
        try self.personal_words.put(owned, .{});
        errdefer _ = self.personal_words.remove(owned);
        const index = lexicalLowerBound(self.personal_order.items, owned);
        try self.personal_order.insert(index, owned);
        return .{};
    }

    fn evictWeakest(self: *AutocompleteEngine) void {
        if (self.personal_order.items.len == 0) return;
        var weakest: usize = 0;
        var weakest_value = retentionValue(self.personal_words.get(self.personal_order.items[0]).?);
        for (self.personal_order.items[1..], 1..) |word, index| {
            const value = retentionValue(self.personal_words.get(word).?);
            if (value < weakest_value or (value == weakest_value and index < weakest)) {
                weakest = index;
                weakest_value = value;
            }
        }
        const word = self.personal_order.orderedRemove(weakest);
        _ = self.personal_words.remove(word);
        self.allocator.free(word);
    }
};

fn normalizeWord(word: []const u8, storage: []u8) ?[]const u8 {
    if (word.len < config.BEHAVIOR.MIN_TRIGGER_LEN or word.len > storage.len) return null;
    for (word, 0..) |character, index| {
        if (!insertion.isWordChar(character)) return null;
        storage[index] = std.ascii.toLower(character);
    }
    return storage[0..word.len];
}

fn dictionaryScore(rank: u32, word: []const u8) i32 {
    const frequency = @as(i32, @intCast(@min(rank, 20_000)));
    return 30_000 - frequency - @as(i32, @intCast(word.len * 3));
}

fn caseMatchBonus(prefix: []const u8) i32 {
    // Output casing follows the prefix, so a candidate that can preserve that
    // casing receives a small explicit score component.
    return if (prefix.len != 0 and std.ascii.isAlphabetic(prefix[0])) 50 else 0;
}

fn personalScore(clock: u64, word: []const u8, stats: PersonalStats, base_rank: ?u32) i32 {
    const age = clock -| stats.last_used;
    const recency: i32 = @intCast(2000 - @min(age, 2000));
    const typed: i32 = @intCast(@min(stats.typed_count, 1000));
    const accepted: i32 = @intCast(@min(stats.accepted_count, 1000));
    const ignores: i32 = @intCast(@min(stats.consecutive_ignores, 100));
    const base = if (base_rank) |rank| dictionaryScore(rank, word) else 28_000;
    return base + typed * 25 + accepted * 120 + recency - ignores * 80 - @as(i32, @intCast(word.len * 3));
}

fn retentionValue(stats: PersonalStats) u128 {
    return @as(u128, stats.accepted_count) * 1_000_000_000 +
        @as(u128, stats.typed_count) * 1_000_000 +
        @as(u128, stats.last_used);
}

fn better(left: ScoredWord, right: ScoredWord) bool {
    if (left.score != right.score) return left.score > right.score;
    return std.mem.order(u8, left.word, right.word) == .lt;
}

fn insertTop(top: *std.BoundedArray(ScoredWord, MAX_SUGGESTIONS), candidate: ScoredWord) void {
    if (top.len < MAX_SUGGESTIONS) {
        top.append(candidate) catch unreachable;
    } else if (!better(candidate, top.get(top.len - 1))) {
        return;
    } else {
        top.set(top.len - 1, candidate);
    }
    var index = top.len - 1;
    while (index > 0 and better(top.get(index), top.get(index - 1))) : (index -= 1) {
        const previous = top.get(index - 1);
        top.set(index - 1, top.get(index));
        top.set(index, previous);
    }
}

fn personalPrefixRange(words: []const []const u8, prefix: []const u8) dict.PrefixRange {
    const start = lexicalLowerBound(words, prefix);
    var end = start;
    while (end < words.len and std.mem.startsWith(u8, words[end], prefix)) : (end += 1) {}
    return .{ .start = start, .end = end };
}

fn lexicalLowerBound(words: []const []const u8, needle: []const u8) usize {
    var low: usize = 0;
    var high = words.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, words[middle], needle) == .lt)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}
