const std = @import("std");
const sysinput = @import("root").sysinput;

const config = sysinput.core.config;
const insertion = sysinput.win32.insertion;
const candidate_model = sysinput.suggestion.candidate;

pub const MIN_CONTEXT_WORDS: usize = 2;
pub const MAX_CONTEXT_WORDS: usize = 5;
pub const MAX_CONTEXT_TRANSITIONS: usize = 20_000;
pub const MAX_CONTEXT_TOKENS: usize = 10_000;
pub const MAX_CONTINUATIONS: usize = 3;
pub const MAX_PHRASE_WORDS: usize = 4;
const MIN_CONFIDENCE: u16 = 600;
const PHRASE_CONFIDENCE: u16 = 850;
const EVICTION_SAMPLE: usize = 64;
const PROFILE_MAGIC = "SYSICTX1";
const PROFILE_VERSION: u16 = 1;
const PROFILE_HEADER_SIZE: usize = 8 + 2 + 4 + 4 + 4;
const MAX_PROFILE_SIZE: usize = 8 * 1024 * 1024;

pub const FeedbackKind = enum(u8) {
    shown,
    accepted,
};

const ContextKey = struct {
    ids: [MAX_CONTEXT_WORDS]u32 = [_]u32{0} ** MAX_CONTEXT_WORDS,
    len: u8 = 0,
};

const Continuation = struct {
    token_id: u32,
    observed_count: u32 = 0,
    shown_count: u32 = 0,
    accepted_count: u32 = 0,
    last_used: u64 = 0,
    consecutive_ignores: u16 = 0,
};

const Bucket = struct {
    items: [MAX_CONTINUATIONS]Continuation = undefined,
    count: u8 = 0,

    fn totalObserved(self: *const Bucket) u64 {
        var total: u64 = 0;
        for (self.items[0..self.count]) |item| total += item.observed_count;
        return total;
    }
};

pub const Prediction = struct {
    text: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    len: u16 = 0,
    kind: candidate_model.CandidateKind = .next_word,
    score: i32 = 0,
    confidence: u16 = 0,

    pub fn textSlice(self: *const Prediction) []const u8 {
        return self.text[0..self.len];
    }
};

pub const PredictionSet = struct {
    items: [config.TEXT.MAX_SUGGESTIONS]Prediction = undefined,
    count: u8 = 0,

    pub fn slice(self: *const PredictionSet) []const Prediction {
        return self.items[0..self.count];
    }
};

pub const ContextModel = struct {
    allocator: std.mem.Allocator,
    token_ids: std.StringHashMap(u32),
    tokens: std.ArrayList([]const u8),
    contexts: std.AutoHashMap(ContextKey, Bucket),
    transition_count: usize,
    history: [MAX_CONTEXT_WORDS]u32,
    history_count: usize,
    usage_clock: u64,
    revision: u64,
    snapshot_target: usize,
    snapshot: [config.TEXT.MAX_BUFFER_SIZE]u8,
    snapshot_len: usize,

    pub fn init(allocator: std.mem.Allocator) !ContextModel {
        var result = ContextModel{
            .allocator = allocator,
            .token_ids = std.StringHashMap(u32).init(allocator),
            .tokens = std.ArrayList([]const u8).init(allocator),
            .contexts = std.AutoHashMap(ContextKey, Bucket).init(allocator),
            .transition_count = 0,
            .history = undefined,
            .history_count = 0,
            .usage_clock = 0,
            .revision = 0,
            .snapshot_target = 0,
            .snapshot = undefined,
            .snapshot_len = 0,
        };
        errdefer result.deinit();

        // A deliberately tiny English seed keeps first-run behavior useful.
        // Personal observations use the same bounded table and can outrank it.
        const seeds = [_][]const u8{
            "please let me know",
            "as soon as possible",
            "looking forward to hearing from you",
            "thank you for your time",
            "feel free to reach out",
            "could you please confirm",
            "let me know if",
        };
        for (seeds) |sequence| {
            for (0..3) |_| try result.observeSequence(sequence);
        }
        result.history_count = 0;
        result.revision = 0;
        return result;
    }

    pub fn deinit(self: *ContextModel) void {
        for (self.tokens.items) |token| self.allocator.free(token);
        self.tokens.deinit();
        self.token_ids.deinit();
        self.contexts.deinit();
    }

    pub fn processTextSnapshot(self: *ContextModel, target: usize, text: []const u8) !void {
        const bounded = text[0..@min(text.len, self.snapshot.len)];
        const appended = target != 0 and target == self.snapshot_target and
            bounded.len >= self.snapshot_len and
            std.mem.eql(u8, bounded[0..self.snapshot_len], self.snapshot[0..self.snapshot_len]);

        if (!appended) {
            try self.rebuildHistory(bounded);
        } else if (bounded.len > self.snapshot_len) {
            var start = self.snapshot_len;
            while (start > 0 and isTokenChar(bounded[start - 1])) start -= 1;
            var word_start: ?usize = null;
            for (bounded[start..], start..) |character, index| {
                if (isTokenChar(character)) {
                    if (word_start == null) word_start = index;
                } else {
                    if (word_start) |word_index| {
                        if (index >= self.snapshot_len) try self.observeWord(bounded[word_index..index]);
                        word_start = null;
                    }
                    if (isHardBoundary(character)) self.history_count = 0;
                }
            }
        }

        @memcpy(self.snapshot[0..bounded.len], bounded);
        self.snapshot_len = bounded.len;
        self.snapshot_target = target;
    }

    pub fn predict(self: *const ContextModel) PredictionSet {
        var result = PredictionSet{};
        if (self.history_count < MIN_CONTEXT_WORDS) return result;
        const context_lookup = self.lookup(self.history[0..self.history_count]) orelse return result;

        var order: [MAX_CONTINUATIONS]usize = undefined;
        for (0..context_lookup.bucket.count) |index| order[index] = index;
        sortContinuationOrder(self, context_lookup.bucket, order[0..context_lookup.bucket.count]);

        for (order[0..context_lookup.bucket.count]) |index| {
            if (result.count >= result.items.len) break;
            const continuation = context_lookup.bucket.items[index];
            const confidence = confidenceFor(context_lookup.bucket, continuation);
            if (confidence < MIN_CONFIDENCE) continue;

            var prediction = Prediction{
                .score = scoreFor(self.usage_clock, continuation, confidence),
                .confidence = confidence,
            };
            var synthetic = self.history;
            var synthetic_count = self.history_count;
            if (!appendPredictionToken(&prediction, self.tokens.items[continuation.token_id])) continue;
            pushHistory(&synthetic, &synthetic_count, continuation.token_id);
            var phrase_words: usize = 1;

            if (confidence >= PHRASE_CONFIDENCE and continuation.observed_count >= 2) {
                while (phrase_words < MAX_PHRASE_WORDS) : (phrase_words += 1) {
                    const extension_lookup = self.lookup(synthetic[0..synthetic_count]) orelse break;
                    const extension = bestContinuation(self, extension_lookup.bucket);
                    const extension_confidence = confidenceFor(extension_lookup.bucket, extension);
                    if (extension_confidence < PHRASE_CONFIDENCE or extension.observed_count < 2) break;
                    if (!appendPredictionToken(&prediction, self.tokens.items[extension.token_id])) break;
                    pushHistory(&synthetic, &synthetic_count, extension.token_id);
                    prediction.confidence = @min(prediction.confidence, extension_confidence);
                    prediction.score += @divTrunc(scoreFor(self.usage_clock, extension, extension_confidence), 8);
                }
            }

            prediction.kind = if (phrase_words > 1) .phrase_completion else .next_word;
            result.items[result.count] = prediction;
            result.count += 1;
        }
        return result;
    }

    pub fn recordFeedback(self: *ContextModel, kind: FeedbackKind, prediction_text: []const u8) void {
        if (self.history_count < MIN_CONTEXT_WORDS) return;
        var synthetic = self.history;
        var synthetic_count = self.history_count;
        var start: ?usize = null;
        var index: usize = 0;
        while (index <= prediction_text.len) : (index += 1) {
            const at_end = index == prediction_text.len;
            const character = if (at_end) @as(u8, ' ') else prediction_text[index];
            if (!at_end and isTokenChar(character)) {
                if (start == null) start = index;
                continue;
            }
            const word_start = start orelse continue;
            start = null;
            const token_id = self.token_ids.get(prediction_text[word_start..index]) orelse break;
            const key = self.lookupKey(synthetic[0..synthetic_count]) orelse break;
            const bucket = self.contexts.getPtr(key) orelse break;
            for (bucket.items[0..bucket.count]) |*continuation| {
                if (continuation.token_id != token_id) continue;
                switch (kind) {
                    .shown => {
                        continuation.shown_count +|= 1;
                        continuation.consecutive_ignores +|= 1;
                    },
                    .accepted => {
                        self.tick();
                        continuation.accepted_count +|= 1;
                        continuation.last_used = self.usage_clock;
                        continuation.consecutive_ignores = 0;
                    },
                }
                self.revision +%= 1;
                break;
            }
            pushHistory(&synthetic, &synthetic_count, token_id);
        }
    }

    pub fn contextCount(self: *const ContextModel) usize {
        return self.contexts.count();
    }

    pub fn transitionCount(self: *const ContextModel) usize {
        return self.transition_count;
    }

    fn restoreTransition(
        self: *ContextModel,
        context_words: []const []const u8,
        next_word: []const u8,
        continuation: Continuation,
    ) !void {
        if (context_words.len < MIN_CONTEXT_WORDS or context_words.len > MAX_CONTEXT_WORDS) {
            return error.InvalidContextProfile;
        }
        var context_ids: [MAX_CONTEXT_WORDS]u32 = undefined;
        for (context_words, 0..) |word, index| {
            context_ids[index] = try self.intern(word) orelse return error.InvalidContextProfile;
        }
        const next_id = try self.intern(next_word) orelse return error.InvalidContextProfile;
        const key = makeKey(context_ids[0..context_words.len]);
        const entry = try self.contexts.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const bucket = entry.value_ptr;
        for (bucket.items[0..bucket.count]) |*existing| {
            if (existing.token_id != next_id) continue;
            existing.* = continuation;
            existing.token_id = next_id;
            self.usage_clock = @max(self.usage_clock, continuation.last_used);
            return;
        }
        if (bucket.count >= MAX_CONTINUATIONS or self.transition_count >= MAX_CONTEXT_TRANSITIONS) return;
        bucket.items[bucket.count] = continuation;
        bucket.items[bucket.count].token_id = next_id;
        bucket.count += 1;
        self.transition_count += 1;
        self.usage_clock = @max(self.usage_clock, continuation.last_used);
    }

    fn observeSequence(self: *ContextModel, sequence: []const u8) !void {
        self.history_count = 0;
        var start: ?usize = null;
        for (sequence, 0..) |character, index| {
            if (isTokenChar(character)) {
                if (start == null) start = index;
            } else if (start) |word_start| {
                try self.observeWord(sequence[word_start..index]);
                start = null;
            }
        }
        if (start) |word_start| try self.observeWord(sequence[word_start..]);
    }

    fn observeWord(self: *ContextModel, word: []const u8) !void {
        const token_id = try self.intern(word) orelse {
            self.history_count = 0;
            return;
        };
        const max_len = @min(self.history_count, MAX_CONTEXT_WORDS);
        if (max_len >= MIN_CONTEXT_WORDS) {
            var context_len = MIN_CONTEXT_WORDS;
            while (context_len <= max_len) : (context_len += 1) {
                const history_start = self.history_count - context_len;
                try self.observeTransition(self.history[history_start..self.history_count], token_id);
            }
        }
        pushHistory(&self.history, &self.history_count, token_id);
    }

    fn observeTransition(self: *ContextModel, history: []const u32, token_id: u32) !void {
        const key = makeKey(history);
        const entry = try self.contexts.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const bucket = entry.value_ptr;

        for (bucket.items[0..bucket.count]) |*continuation| {
            if (continuation.token_id != token_id) continue;
            self.tick();
            continuation.observed_count +|= 1;
            continuation.last_used = self.usage_clock;
            self.revision +%= 1;
            return;
        }

        if (bucket.count < MAX_CONTINUATIONS) {
            if (self.transition_count >= MAX_CONTEXT_TRANSITIONS) self.evictSampledTransition();
            if (self.transition_count >= MAX_CONTEXT_TRANSITIONS) return;
            self.tick();
            bucket.items[bucket.count] = .{ .token_id = token_id, .observed_count = 1, .last_used = self.usage_clock };
            bucket.count += 1;
            self.transition_count += 1;
            self.revision +%= 1;
            return;
        }

        var weakest: usize = 0;
        for (1..bucket.count) |index| {
            if (weaker(bucket.items[index], bucket.items[weakest])) weakest = index;
        }
        self.tick();
        bucket.items[weakest] = .{ .token_id = token_id, .observed_count = 1, .last_used = self.usage_clock };
        self.revision +%= 1;
    }

    fn rebuildHistory(self: *ContextModel, text: []const u8) !void {
        self.history_count = 0;
        var start: ?usize = null;
        for (text, 0..) |character, index| {
            if (isTokenChar(character)) {
                if (start == null) start = index;
            } else {
                if (start) |word_start| {
                    if (try self.intern(text[word_start..index])) |token_id| {
                        pushHistory(&self.history, &self.history_count, token_id);
                    }
                    start = null;
                }
                if (isHardBoundary(character)) self.history_count = 0;
            }
        }
        // A trailing token is the current incomplete word and is intentionally
        // excluded until a delimiter confirms it.
    }

    fn intern(self: *ContextModel, word: []const u8) !?u32 {
        var storage: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const normalized = normalizeToken(word, &storage) orelse return null;
        if (self.token_ids.get(normalized)) |token_id| return token_id;
        if (self.tokens.items.len >= MAX_CONTEXT_TOKENS) return null;
        const owned = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(owned);
        const token_id: u32 = @intCast(self.tokens.items.len);
        try self.tokens.append(owned);
        errdefer _ = self.tokens.pop();
        try self.token_ids.put(owned, token_id);
        return token_id;
    }

    const Lookup = struct { key: ContextKey, bucket: *const Bucket };

    fn lookup(self: *const ContextModel, history: []const u32) ?Lookup {
        const key = self.lookupKey(history) orelse return null;
        return .{ .key = key, .bucket = self.contexts.getPtr(key).? };
    }

    fn lookupKey(self: *const ContextModel, history: []const u32) ?ContextKey {
        var length = @min(history.len, MAX_CONTEXT_WORDS);
        while (length >= MIN_CONTEXT_WORDS) : (length -= 1) {
            const key = makeKey(history[history.len - length ..]);
            if (self.contexts.contains(key)) return key;
            if (length == MIN_CONTEXT_WORDS) break;
        }
        return null;
    }

    fn evictSampledTransition(self: *ContextModel) void {
        var iterator = self.contexts.iterator();
        var sampled: usize = 0;
        var selected_key: ?ContextKey = null;
        var selected_index: usize = 0;
        var selected: Continuation = undefined;
        while (iterator.next()) |entry| {
            for (entry.value_ptr.items[0..entry.value_ptr.count], 0..) |continuation, index| {
                if (selected_key == null or weaker(continuation, selected)) {
                    selected_key = entry.key_ptr.*;
                    selected_index = index;
                    selected = continuation;
                }
                sampled += 1;
                if (sampled >= EVICTION_SAMPLE) break;
            }
            if (sampled >= EVICTION_SAMPLE) break;
        }
        const key = selected_key orelse return;
        const bucket = self.contexts.getPtr(key) orelse return;
        var index = selected_index;
        while (index + 1 < bucket.count) : (index += 1) bucket.items[index] = bucket.items[index + 1];
        bucket.count -= 1;
        self.transition_count -= 1;
        if (bucket.count == 0) _ = self.contexts.remove(key);
    }

    fn tick(self: *ContextModel) void {
        self.usage_clock +%= 1;
        if (self.usage_clock == 0) self.usage_clock = 1;
    }
};

pub const ContextProfileStore = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    path: []u8,
    temporary_path: []u8,

    pub fn initDefault(allocator: std.mem.Allocator) !ContextProfileStore {
        const executable_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(executable_dir);
        const directory = try std.fs.path.join(allocator, &.{ executable_dir, "data" });
        errdefer allocator.free(directory);
        const path = try std.fs.path.join(allocator, &.{ directory, "context.bin" });
        errdefer allocator.free(path);
        const temporary_path = try std.fs.path.join(allocator, &.{ directory, "context.bin.tmp" });
        return .{ .allocator = allocator, .directory = directory, .path = path, .temporary_path = temporary_path };
    }

    pub fn deinit(self: *ContextProfileStore) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.path);
        self.allocator.free(self.temporary_path);
    }

    pub fn load(self: *const ContextProfileStore, model: *ContextModel) !void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, MAX_PROFILE_SIZE) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(bytes);
        try decodeProfileInto(model, bytes);
    }

    pub fn save(self: *const ContextProfileStore, model: *const ContextModel) !void {
        try std.fs.cwd().makePath(self.directory);
        const bytes = try encodeProfile(self.allocator, model);
        defer self.allocator.free(bytes);
        var file = try std.fs.cwd().createFile(self.temporary_path, .{ .truncate = true });
        var file_open = true;
        defer if (file_open) file.close();
        errdefer std.fs.cwd().deleteFile(self.temporary_path) catch {};
        try file.writeAll(bytes);
        try file.sync();
        file.close();
        file_open = false;
        try std.fs.renameAbsolute(self.temporary_path, self.path);
    }
};

pub fn encodeProfile(allocator: std.mem.Allocator, model: *const ContextModel) ![]u8 {
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();
    var iterator = model.contexts.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        for (entry.value_ptr.items[0..entry.value_ptr.count]) |continuation| {
            try payload.append(key.len);
            for (key.ids[0..key.len]) |token_id| {
                try appendProfileWord(&payload, model.tokens.items[token_id]);
            }
            try appendProfileWord(&payload, model.tokens.items[continuation.token_id]);
            try appendProfileInt(&payload, u32, continuation.observed_count);
            try appendProfileInt(&payload, u32, continuation.shown_count);
            try appendProfileInt(&payload, u32, continuation.accepted_count);
            try appendProfileInt(&payload, u64, continuation.last_used);
            try appendProfileInt(&payload, u16, continuation.consecutive_ignores);
        }
    }

    var output = try std.ArrayList(u8).initCapacity(allocator, PROFILE_HEADER_SIZE + payload.items.len);
    errdefer output.deinit();
    try output.appendSlice(PROFILE_MAGIC);
    try appendProfileInt(&output, u16, PROFILE_VERSION);
    try appendProfileInt(&output, u32, @intCast(model.transition_count));
    try appendProfileInt(&output, u32, @intCast(payload.items.len));
    try appendProfileInt(&output, u32, std.hash.Crc32.hash(payload.items));
    try output.appendSlice(payload.items);
    return output.toOwnedSlice();
}

pub fn decodeProfileInto(model: *ContextModel, bytes: []const u8) !void {
    if (bytes.len < PROFILE_HEADER_SIZE or bytes.len > MAX_PROFILE_SIZE) return error.InvalidContextProfile;
    if (!std.mem.eql(u8, bytes[0..PROFILE_MAGIC.len], PROFILE_MAGIC)) return error.InvalidContextProfile;
    var offset: usize = PROFILE_MAGIC.len;
    if (try readProfileInt(u16, bytes, &offset) != PROFILE_VERSION) return error.UnsupportedContextProfile;
    const record_count = try readProfileInt(u32, bytes, &offset);
    if (record_count > MAX_CONTEXT_TRANSITIONS) return error.InvalidContextProfile;
    const payload_len = try readProfileInt(u32, bytes, &offset);
    const checksum = try readProfileInt(u32, bytes, &offset);
    if (payload_len != bytes.len - PROFILE_HEADER_SIZE) return error.InvalidContextProfile;
    if (std.hash.Crc32.hash(bytes[PROFILE_HEADER_SIZE..]) != checksum) return error.InvalidContextProfile;

    const TemporaryRecord = struct {
        words: [MAX_CONTEXT_WORDS][]const u8,
        word_count: u8,
        next_word: []const u8,
        continuation: Continuation,
    };
    var records = std.ArrayList(TemporaryRecord).init(model.allocator);
    defer records.deinit();
    offset = PROFILE_HEADER_SIZE;
    for (0..record_count) |_| {
        if (offset >= bytes.len) return error.InvalidContextProfile;
        const word_count = bytes[offset];
        offset += 1;
        if (word_count < MIN_CONTEXT_WORDS or word_count > MAX_CONTEXT_WORDS) return error.InvalidContextProfile;
        var record: TemporaryRecord = .{
            .words = undefined,
            .word_count = word_count,
            .next_word = undefined,
            .continuation = undefined,
        };
        for (0..word_count) |index| record.words[index] = try readProfileWord(bytes, &offset);
        record.next_word = try readProfileWord(bytes, &offset);
        record.continuation = .{
            .token_id = 0,
            .observed_count = try readProfileInt(u32, bytes, &offset),
            .shown_count = try readProfileInt(u32, bytes, &offset),
            .accepted_count = try readProfileInt(u32, bytes, &offset),
            .last_used = try readProfileInt(u64, bytes, &offset),
            .consecutive_ignores = try readProfileInt(u16, bytes, &offset),
        };
        if (record.continuation.observed_count == 0) return error.InvalidContextProfile;
        try records.append(record);
    }
    if (offset != bytes.len) return error.InvalidContextProfile;
    for (records.items) |record| {
        try model.restoreTransition(record.words[0..record.word_count], record.next_word, record.continuation);
    }
}

fn appendProfileWord(payload: *std.ArrayList(u8), word: []const u8) !void {
    if (word.len == 0 or word.len > config.TEXT.MAX_SUGGESTION_LEN) return error.InvalidContextProfile;
    try appendProfileInt(payload, u16, @intCast(word.len));
    try payload.appendSlice(word);
}

fn appendProfileInt(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(&bytes);
}

fn readProfileInt(comptime T: type, bytes: []const u8, offset: *usize) !T {
    if (offset.* + @sizeOf(T) > bytes.len) return error.InvalidContextProfile;
    const value = std.mem.readInt(T, bytes[offset.*..][0..@sizeOf(T)], .little);
    offset.* += @sizeOf(T);
    return value;
}

fn readProfileWord(bytes: []const u8, offset: *usize) ![]const u8 {
    const length = try readProfileInt(u16, bytes, offset);
    if (length == 0 or length > config.TEXT.MAX_SUGGESTION_LEN or offset.* + length > bytes.len) {
        return error.InvalidContextProfile;
    }
    const word = bytes[offset.* .. offset.* + length];
    offset.* += length;
    return word;
}

fn isTokenChar(character: u8) bool {
    return insertion.isWordChar(character);
}

fn isHardBoundary(character: u8) bool {
    return character == '.' or character == '!' or character == '?' or character == '\n' or character == '\r';
}

fn normalizeToken(word: []const u8, storage: []u8) ?[]const u8 {
    if (word.len == 0 or word.len > storage.len) return null;
    for (word, 0..) |character, index| {
        if (!isTokenChar(character)) return null;
        storage[index] = std.ascii.toLower(character);
    }
    return storage[0..word.len];
}

fn makeKey(ids: []const u32) ContextKey {
    var key = ContextKey{ .len = @intCast(ids.len) };
    @memcpy(key.ids[0..ids.len], ids);
    return key;
}

fn pushHistory(history: *[MAX_CONTEXT_WORDS]u32, count: *usize, token_id: u32) void {
    if (count.* < history.len) {
        history[count.*] = token_id;
        count.* += 1;
        return;
    }
    std.mem.copyForwards(u32, history[0 .. history.len - 1], history[1..]);
    history[history.len - 1] = token_id;
}

fn confidenceFor(bucket: *const Bucket, continuation: Continuation) u16 {
    const total = bucket.totalObserved();
    if (total == 0) return 0;
    const ratio_component = @min(@as(u64, 700), continuation.observed_count * 700 / total);
    const support_component = @min(@as(u64, 300), @as(u64, continuation.observed_count) * 80);
    const acceptance_component = @min(@as(u64, 150), @as(u64, continuation.accepted_count) * 30);
    const ignore_penalty = @min(@as(u64, 600), @as(u64, continuation.consecutive_ignores) * 20);
    const positive = @min(@as(u64, 1000), ratio_component + support_component + acceptance_component);
    return @intCast(positive -| ignore_penalty);
}

fn scoreFor(clock: u64, continuation: Continuation, confidence: u16) i32 {
    const age = clock -| continuation.last_used;
    const recency: i32 = @intCast(500 - @min(age, 500));
    const accepted: i32 = @intCast(@min(continuation.accepted_count, 1000));
    const ignored: i32 = @intCast(@min(continuation.consecutive_ignores, 100));
    return @as(i32, confidence) * 10 + accepted * 80 + recency - ignored * 60;
}

fn weaker(left: Continuation, right: Continuation) bool {
    const left_value = @as(u128, left.accepted_count) * 1_000_000 +
        @as(u128, left.observed_count) * 1_000 + left.last_used;
    const right_value = @as(u128, right.accepted_count) * 1_000_000 +
        @as(u128, right.observed_count) * 1_000 + right.last_used;
    return left_value < right_value;
}

fn better(self: *const ContextModel, left: Continuation, right: Continuation) bool {
    const left_confidence = confidenceForSingle(left);
    const right_confidence = confidenceForSingle(right);
    if (left_confidence != right_confidence) return left_confidence > right_confidence;
    return std.mem.order(u8, self.tokens.items[left.token_id], self.tokens.items[right.token_id]) == .lt;
}

fn confidenceForSingle(continuation: Continuation) u64 {
    return @as(u64, continuation.observed_count) * 1000 + @as(u64, continuation.accepted_count) * 4000;
}

fn sortContinuationOrder(
    self: *const ContextModel,
    bucket: *const Bucket,
    order: []usize,
) void {
    for (1..order.len) |index| {
        var current = index;
        while (current > 0 and better(self, bucket.items[order[current]], bucket.items[order[current - 1]])) {
            const temporary = order[current - 1];
            order[current - 1] = order[current];
            order[current] = temporary;
            current -= 1;
        }
    }
}

fn bestContinuation(self: *const ContextModel, bucket: *const Bucket) Continuation {
    var best = bucket.items[0];
    for (bucket.items[1..bucket.count]) |candidate| {
        if (better(self, candidate, best)) best = candidate;
    }
    return best;
}

fn appendPredictionToken(prediction: *Prediction, token: []const u8) bool {
    const separator_len: usize = if (prediction.len == 0) 0 else 1;
    const start: usize = prediction.len;
    if (start + separator_len + token.len > prediction.text.len) return false;
    if (separator_len != 0) prediction.text[start] = ' ';
    @memcpy(prediction.text[start + separator_len .. start + separator_len + token.len], token);
    prediction.len = @intCast(start + separator_len + token.len);
    return true;
}
