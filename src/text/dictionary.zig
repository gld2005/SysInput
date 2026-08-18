const std = @import("std");
const sysinput = @import("root").sysinput;

const debug = sysinput.core.debug;

pub const FALLBACK_WORDS = [_][]const u8{
    "the", "be", "to",   "of",   "and", "in",   "that", "have", "it",  "for",
    "not", "on", "with", "this", "but", "from", "they", "we",   "say", "you",
};

pub const RankedWord = struct {
    text: []const u8,
    rank: u32,
};

pub const PrefixRange = struct {
    start: usize,
    end: usize,
};

/// The source file order is the frequency rank. The lookup map is retained for
/// spell checking while ranked_words is immutable and lexically sorted for
/// bounded prefix lookup.
pub const Dictionary = struct {
    word_map: std.StringHashMap(u32),
    ranked_words: std.ArrayList(RankedWord),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Dictionary {
        var result = Dictionary{
            .word_map = std.StringHashMap(u32).init(allocator),
            .ranked_words = std.ArrayList(RankedWord).init(allocator),
            .allocator = allocator,
        };
        errdefer result.deinit();

        const paths = [_][]const u8{
            "dictionary.txt",
            "resources/dictionary.txt",
            "../resources/dictionary.txt",
            "../../resources/dictionary.txt",
        };
        var loaded = false;
        for (paths) |path| {
            loaded = result.loadFromFile(path) catch |err| {
                debug.debugPrint("Error loading dictionary from {s}: {}\n", .{ path, err });
                continue;
            };
            if (loaded) break;
        }
        if (!loaded) {
            for (FALLBACK_WORDS, 0..) |word, rank| {
                try result.addOwnedRanked(word, @intCast(rank));
            }
        }
        std.mem.sort(RankedWord, result.ranked_words.items, {}, lessThanWord);
        return result;
    }

    pub fn deinit(self: *Dictionary) void {
        for (self.ranked_words.items) |entry| self.allocator.free(entry.text);
        self.ranked_words.deinit();
        self.word_map.deinit();
    }

    pub fn contains(self: *const Dictionary, word: []const u8) bool {
        var lower: [256]u8 = undefined;
        const normalized = normalize(word, &lower) orelse return false;
        return self.word_map.contains(normalized);
    }

    pub fn rankOf(self: *const Dictionary, word: []const u8) ?u32 {
        var lower: [256]u8 = undefined;
        const normalized = normalize(word, &lower) orelse return null;
        return self.word_map.get(normalized);
    }

    /// Returns the only lexical interval that can contain the prefix. Callers
    /// inspect this interval, never the complete dictionary.
    pub fn prefixRange(self: *const Dictionary, lower_prefix: []const u8) PrefixRange {
        const start = lowerBound(self.ranked_words.items, lower_prefix);
        var end = start;
        while (end < self.ranked_words.items.len and
            std.mem.startsWith(u8, self.ranked_words.items[end].text, lower_prefix)) : (end += 1)
        {}
        return .{ .start = start, .end = end };
    }

    fn loadFromFile(self: *Dictionary, filename: []const u8) !bool {
        const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        defer file.close();
        const stat = try file.stat();
        if (stat.size > 10_000_000) return error.FileTooLarge;
        const contents = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(contents);
        if (try file.readAll(contents) != contents.len) return error.ReadError;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var source_rank: u32 = 0;
        while (lines.next()) |line| {
            const word = std.mem.trim(u8, line, " \t\r\n");
            if (word.len < 2 or word.len > 30) continue;
            try self.addOwnedRanked(word, source_rank);
            source_rank = std.math.add(u32, source_rank, 1) catch std.math.maxInt(u32);
        }
        debug.debugPrint("Loaded {d} ranked dictionary words from {s}\n", .{ self.ranked_words.items.len, filename });
        return self.ranked_words.items.len != 0;
    }

    fn addOwnedRanked(self: *Dictionary, word: []const u8, rank: u32) !void {
        const owned = try self.allocator.dupe(u8, word);
        errdefer self.allocator.free(owned);
        for (owned) |*character| character.* = std.ascii.toLower(character.*);
        if (self.word_map.contains(owned)) {
            self.allocator.free(owned);
            return;
        }
        try self.ranked_words.append(.{ .text = owned, .rank = rank });
        errdefer _ = self.ranked_words.pop();
        try self.word_map.put(owned, rank);
    }
};

fn normalize(word: []const u8, storage: []u8) ?[]const u8 {
    if (word.len > storage.len) return null;
    for (word, 0..) |character, index| storage[index] = std.ascii.toLower(character);
    return storage[0..word.len];
}

fn lessThanWord(_: void, left: RankedWord, right: RankedWord) bool {
    return std.mem.order(u8, left.text, right.text) == .lt;
}

fn lowerBound(words: []const RankedWord, needle: []const u8) usize {
    var low: usize = 0;
    var high = words.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.mem.order(u8, words[mid].text, needle) == .lt)
            low = mid + 1
        else
            high = mid;
    }
    return low;
}
