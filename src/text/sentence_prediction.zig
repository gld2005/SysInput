const std = @import("std");
const sysinput = @import("root").sysinput;

const config = sysinput.core.config;
const insertion = sysinput.win32.insertion;
const candidate_model = sysinput.suggestion.candidate;

pub const MIN_SENTENCE_WORDS: usize = 3;
pub const MAX_SENTENCE_TOKENS: usize = 32;
pub const MAX_PREDICTED_WORDS: usize = 12;
pub const MAX_SENTENCE_RECORDS: usize = 2_000;
pub const MAX_SENTENCE_TOKENS_INTERNED: usize = 10_000;
const MAX_BUCKET_RECORDS: usize = 8;
const EVICTION_SAMPLE: usize = 64;
const MIN_REPEAT_COUNT: u32 = 2;
const MIN_CONFIDENCE: u16 = 700;
const PROFILE_MAGIC = "SYSISNT1";
const PROFILE_VERSION: u16 = 1;
const PROFILE_HEADER_SIZE: usize = 8 + 2 + 4 + 4 + 4;
const MAX_PROFILE_SIZE: usize = 8 * 1024 * 1024;

pub const FeedbackKind = enum(u8) {
    shown,
    accepted,
};

const FirstWordsKey = struct {
    ids: [MIN_SENTENCE_WORDS]u32,
};

const RecordBucket = struct {
    indices: [MAX_BUCKET_RECORDS]u16 = undefined,
    count: u8 = 0,
};

const SentenceRecord = struct {
    tokens: [MAX_SENTENCE_TOKENS]u32 = undefined,
    token_count: u8 = 0,
    word_count: u8 = 0,
    repeat_count: u32 = 0,
    shown_count: u32 = 0,
    accepted_count: u32 = 0,
    last_used: u64 = 0,
    consecutive_ignores: u16 = 0,
};

pub const Prediction = struct {
    text: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    len: u16 = 0,
    score: i32 = 0,
    confidence: u16 = 0,
    chunks: [candidate_model.MAX_CHUNKS]candidate_model.Chunk = undefined,
    chunk_count: u8 = 0,
    record_index: u16 = 0,

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

pub const SentenceModel = struct {
    allocator: std.mem.Allocator,
    token_ids: std.StringHashMap(u32),
    tokens: std.ArrayList([]const u8),
    records: std.ArrayList(SentenceRecord),
    prefix_index: std.AutoHashMap(FirstWordsKey, RecordBucket),
    current_tokens: [MAX_SENTENCE_TOKENS]u32,
    current_count: usize,
    current_word_count: usize,
    current_overflow: bool,
    usage_clock: u64,
    revision: u64,
    eviction_cursor: usize,
    snapshot_target: usize,
    snapshot: [config.TEXT.MAX_BUFFER_SIZE]u8,
    snapshot_len: usize,

    pub fn init(allocator: std.mem.Allocator) SentenceModel {
        return .{
            .allocator = allocator,
            .token_ids = std.StringHashMap(u32).init(allocator),
            .tokens = std.ArrayList([]const u8).init(allocator),
            .records = std.ArrayList(SentenceRecord).init(allocator),
            .prefix_index = std.AutoHashMap(FirstWordsKey, RecordBucket).init(allocator),
            .current_tokens = undefined,
            .current_count = 0,
            .current_word_count = 0,
            .current_overflow = false,
            .usage_clock = 0,
            .revision = 0,
            .eviction_cursor = 0,
            .snapshot_target = 0,
            .snapshot = undefined,
            .snapshot_len = 0,
        };
    }

    pub fn deinit(self: *SentenceModel) void {
        var token_iterator = self.token_ids.keyIterator();
        while (token_iterator.next()) |token| self.allocator.free(token.*);
        for (self.tokens.items) |token| self.allocator.free(token);
        self.tokens.deinit();
        self.token_ids.deinit();
        self.records.deinit();
        self.prefix_index.deinit();
    }

    pub fn processTextSnapshot(self: *SentenceModel, target: usize, text: []const u8) !void {
        try self.processTextSnapshotWithLearning(target, text, true);
    }

    pub fn processTextSnapshotWithLearning(self: *SentenceModel, target: usize, text: []const u8, learn: bool) !void {
        const bounded = text[0..@min(text.len, self.snapshot.len)];
        const appended = target != 0 and target == self.snapshot_target and
            bounded.len >= self.snapshot_len and
            std.mem.eql(u8, bounded[0..self.snapshot_len], self.snapshot[0..self.snapshot_len]);

        if (!appended) {
            try self.rebuildCurrentSentence(bounded, learn);
        } else if (bounded.len > self.snapshot_len) {
            try self.consumeAppended(bounded, self.snapshot_len, learn);
        }

        @memcpy(self.snapshot[0..bounded.len], bounded);
        self.snapshot_len = bounded.len;
        self.snapshot_target = target;
    }

    pub fn predict(self: *const SentenceModel) PredictionSet {
        var result = PredictionSet{};
        if (self.current_word_count < MIN_SENTENCE_WORDS or self.current_overflow) return result;
        const key = firstWordsKey(self.current_tokens[0..self.current_count], self.tokens.items) orelse return result;
        const bucket = self.prefix_index.get(key) orelse return result;

        for (bucket.indices[0..bucket.count]) |record_index| {
            const record = self.records.items[record_index];
            if (record.repeat_count < MIN_REPEAT_COUNT or self.current_count >= record.token_count) continue;
            if (!std.mem.eql(u32, self.current_tokens[0..self.current_count], record.tokens[0..self.current_count])) continue;
            const confidence = confidenceFor(record);
            if (confidence < MIN_CONFIDENCE) continue;
            var prediction = buildPrediction(self, record_index, record, confidence) orelse continue;
            insertPrediction(&result, &prediction);
        }
        return result;
    }

    pub fn recordFeedback(self: *SentenceModel, kind: FeedbackKind, prediction_text: []const u8) void {
        const predictions = self.predict();
        for (predictions.slice()) |prediction| {
            const predicted = prediction.textSlice();
            const matches = switch (kind) {
                .shown => std.mem.eql(u8, predicted, prediction_text),
                .accepted => isAcceptedPrefix(predicted, prediction_text),
            };
            if (!matches) continue;
            const record = &self.records.items[prediction.record_index];
            switch (kind) {
                .shown => {
                    record.shown_count +|= 1;
                    record.consecutive_ignores +|= 1;
                },
                .accepted => {
                    self.tick();
                    record.accepted_count +|= 1;
                    record.last_used = self.usage_clock;
                    record.consecutive_ignores = 0;
                },
            }
            self.revision +%= 1;
            return;
        }
    }

    pub fn recordCount(self: *const SentenceModel) usize {
        return self.records.items.len;
    }

    pub fn repeatedRecordCount(self: *const SentenceModel) usize {
        var count: usize = 0;
        for (self.records.items) |record| {
            if (record.repeat_count >= MIN_REPEAT_COUNT) count += 1;
        }
        return count;
    }

    fn consumeAppended(self: *SentenceModel, text: []const u8, previous_len: usize, learn: bool) !void {
        var scan_start = previous_len;
        while (scan_start > 0 and isWordChar(text[scan_start - 1])) scan_start -= 1;
        var word_start: ?usize = null;
        for (text[scan_start..], scan_start..) |character, index| {
            if (isWordChar(character)) {
                if (word_start == null) word_start = index;
                continue;
            }
            if (word_start) |start| {
                if (index >= previous_len) try self.observeWord(text[start..index], learn);
                word_start = null;
            }
            if (index < previous_len) continue;
            if (isSoftPunctuation(character)) {
                try self.observePunctuation(character, learn);
            } else if (isHardBoundary(character)) {
                if (learn) try self.finishSentence() else self.resetCurrent();
            }
        }
    }

    fn rebuildCurrentSentence(self: *SentenceModel, text: []const u8, learn: bool) !void {
        self.resetCurrent();
        var word_start: ?usize = null;
        for (text, 0..) |character, index| {
            if (isWordChar(character)) {
                if (word_start == null) word_start = index;
                continue;
            }
            if (word_start) |start| {
                if (if (learn) try self.intern(text[start..index]) else self.findToken(text[start..index])) |token_id| {
                    try self.pushCurrentToken(token_id, true);
                } else {
                    self.current_overflow = true;
                }
                word_start = null;
            }
            if (isSoftPunctuation(character)) {
                var punctuation = [_]u8{character};
                if (if (learn) try self.intern(&punctuation) else self.findToken(&punctuation)) |token_id| {
                    try self.pushCurrentToken(token_id, false);
                } else {
                    self.current_overflow = true;
                }
            } else if (isHardBoundary(character)) {
                self.resetCurrent();
            }
        }
        // A trailing word is still being typed and is not part of the confirmed
        // sentence prefix until a delimiter arrives.
    }

    fn observeWord(self: *SentenceModel, word: []const u8, learn: bool) !void {
        const token_id = (if (learn) try self.intern(word) else self.findToken(word)) orelse {
            self.current_overflow = true;
            return;
        };
        try self.pushCurrentToken(token_id, true);
    }

    fn observePunctuation(self: *SentenceModel, punctuation: u8, learn: bool) !void {
        var text = [_]u8{punctuation};
        const token_id = (if (learn) try self.intern(&text) else self.findToken(&text)) orelse return;
        try self.pushCurrentToken(token_id, false);
    }

    fn pushCurrentToken(self: *SentenceModel, token_id: u32, is_word: bool) !void {
        if (self.current_count >= self.current_tokens.len) {
            self.current_overflow = true;
            return;
        }
        self.current_tokens[self.current_count] = token_id;
        self.current_count += 1;
        if (is_word) self.current_word_count += 1;
    }

    fn finishSentence(self: *SentenceModel) !void {
        defer self.resetCurrent();
        if (self.current_overflow or self.current_word_count < MIN_SENTENCE_WORDS or self.current_count == 0) return;
        const tokens = self.current_tokens[0..self.current_count];
        const key = firstWordsKey(tokens, self.tokens.items) orelse return;
        const bucket_entry = try self.prefix_index.getOrPut(key);
        if (!bucket_entry.found_existing) bucket_entry.value_ptr.* = .{};
        var bucket = bucket_entry.value_ptr;

        for (bucket.indices[0..bucket.count]) |record_index| {
            const record = &self.records.items[record_index];
            if (record.token_count == tokens.len and std.mem.eql(u32, record.tokens[0..record.token_count], tokens)) {
                self.tick();
                record.repeat_count +|= 1;
                record.last_used = self.usage_clock;
                self.revision +%= 1;
                return;
            }
        }

        var record_index: usize = undefined;
        if (bucket.count >= bucket.indices.len) {
            record_index = weakestInBucket(self, bucket);
            self.removeFromPrefix(record_index);
            bucket = self.prefix_index.getPtr(key).?;
        } else if (self.records.items.len < MAX_SENTENCE_RECORDS) {
            record_index = self.records.items.len;
            try self.records.append(.{});
        } else {
            record_index = self.sampleWeakRecord();
            self.removeFromPrefix(record_index);
            bucket = self.prefix_index.getPtr(key).?;
        }

        self.tick();
        var record = SentenceRecord{
            .token_count = @intCast(tokens.len),
            .word_count = @intCast(self.current_word_count),
            .repeat_count = 1,
            .last_used = self.usage_clock,
        };
        @memcpy(record.tokens[0..tokens.len], tokens);
        self.records.items[record_index] = record;
        if (bucket.count < bucket.indices.len) {
            bucket.indices[bucket.count] = @intCast(record_index);
            bucket.count += 1;
        }
        self.revision +%= 1;
    }

    fn removeFromPrefix(self: *SentenceModel, record_index: usize) void {
        const old_record = self.records.items[record_index];
        const old_key = firstWordsKey(old_record.tokens[0..old_record.token_count], self.tokens.items) orelse return;
        const bucket = self.prefix_index.getPtr(old_key) orelse return;
        var index: usize = 0;
        while (index < bucket.count) : (index += 1) {
            if (bucket.indices[index] != record_index) continue;
            var shift = index;
            while (shift + 1 < bucket.count) : (shift += 1) bucket.indices[shift] = bucket.indices[shift + 1];
            bucket.count -= 1;
            break;
        }
        if (bucket.count == 0) _ = self.prefix_index.remove(old_key);
    }

    fn sampleWeakRecord(self: *SentenceModel) usize {
        var selected = self.eviction_cursor % self.records.items.len;
        var offset: usize = 1;
        while (offset < @min(EVICTION_SAMPLE, self.records.items.len)) : (offset += 1) {
            const index = (self.eviction_cursor + offset) % self.records.items.len;
            if (weaker(self.records.items[index], self.records.items[selected])) selected = index;
        }
        self.eviction_cursor = (self.eviction_cursor + EVICTION_SAMPLE) % self.records.items.len;
        return selected;
    }

    fn intern(self: *SentenceModel, token: []const u8) !?u32 {
        var storage: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const normalized = normalizeToken(token, &storage) orelse return null;
        if (self.token_ids.get(normalized)) |token_id| return token_id;
        if (self.tokens.items.len >= MAX_SENTENCE_TOKENS_INTERNED) return null;
        const owned_key = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(owned_key);
        const owned_display = try self.allocator.dupe(u8, token);
        errdefer self.allocator.free(owned_display);
        const token_id: u32 = @intCast(self.tokens.items.len);
        try self.tokens.append(owned_display);
        errdefer _ = self.tokens.pop();
        try self.token_ids.put(owned_key, token_id);
        return token_id;
    }

    fn findToken(self: *const SentenceModel, token: []const u8) ?u32 {
        var normalized_storage: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
        const normalized = normalizeToken(token, &normalized_storage) orelse return null;
        return self.token_ids.get(normalized);
    }

    fn restoreRecord(self: *SentenceModel, source: StoredRecord) !void {
        if (self.records.items.len >= MAX_SENTENCE_RECORDS) return;
        var record = SentenceRecord{
            .token_count = source.token_count,
            .repeat_count = source.repeat_count,
            .shown_count = source.shown_count,
            .accepted_count = source.accepted_count,
            .last_used = source.last_used,
            .consecutive_ignores = source.consecutive_ignores,
        };
        for (source.tokens[0..source.token_count], 0..) |token, index| {
            const token_id = try self.intern(token) orelse return error.InvalidSentenceProfile;
            record.tokens[index] = token_id;
            if (!isPunctuationToken(token)) record.word_count += 1;
        }
        if (record.word_count < MIN_SENTENCE_WORDS or record.repeat_count < MIN_REPEAT_COUNT) {
            return error.InvalidSentenceProfile;
        }
        const key = firstWordsKey(record.tokens[0..record.token_count], self.tokens.items) orelse return error.InvalidSentenceProfile;
        const entry = try self.prefix_index.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (entry.value_ptr.count >= entry.value_ptr.indices.len) return;
        const index = self.records.items.len;
        try self.records.append(record);
        entry.value_ptr.indices[entry.value_ptr.count] = @intCast(index);
        entry.value_ptr.count += 1;
        self.usage_clock = @max(self.usage_clock, record.last_used);
    }

    fn resetCurrent(self: *SentenceModel) void {
        self.current_count = 0;
        self.current_word_count = 0;
        self.current_overflow = false;
    }

    fn tick(self: *SentenceModel) void {
        self.usage_clock +%= 1;
        if (self.usage_clock == 0) self.usage_clock = 1;
    }
};

fn isAcceptedPrefix(prediction: []const u8, accepted: []const u8) bool {
    if (accepted.len == 0 or accepted.len > prediction.len) return false;
    if (!std.mem.startsWith(u8, prediction, accepted)) return false;
    return accepted.len == prediction.len or std.ascii.isWhitespace(prediction[accepted.len]);
}

const StoredRecord = struct {
    tokens: [MAX_SENTENCE_TOKENS][]const u8,
    token_count: u8,
    repeat_count: u32,
    shown_count: u32,
    accepted_count: u32,
    last_used: u64,
    consecutive_ignores: u16,
};

pub const SentenceProfileStore = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    path: []u8,
    temporary_path: []u8,

    pub fn initDefault(allocator: std.mem.Allocator) !SentenceProfileStore {
        const executable_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(executable_dir);
        const directory = try std.fs.path.join(allocator, &.{ executable_dir, "data" });
        defer allocator.free(directory);
        return initAt(allocator, directory);
    }

    pub fn initAt(allocator: std.mem.Allocator, directory_path: []const u8) !SentenceProfileStore {
        const directory = try allocator.dupe(u8, directory_path);
        errdefer allocator.free(directory);
        const path = try std.fs.path.join(allocator, &.{ directory, "sentences.bin" });
        errdefer allocator.free(path);
        const temporary_path = try std.fs.path.join(allocator, &.{ directory, "sentences.bin.tmp" });
        return .{ .allocator = allocator, .directory = directory, .path = path, .temporary_path = temporary_path };
    }

    pub fn deinit(self: *SentenceProfileStore) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.path);
        self.allocator.free(self.temporary_path);
    }

    pub fn load(self: *const SentenceProfileStore, model: *SentenceModel) !void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, MAX_PROFILE_SIZE) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(bytes);
        try decodeProfileInto(model, bytes);
    }

    pub fn save(self: *const SentenceProfileStore, model: *const SentenceModel) !void {
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

pub fn encodeProfile(allocator: std.mem.Allocator, model: *const SentenceModel) ![]u8 {
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();
    var persisted_count: u32 = 0;
    for (model.records.items) |record| {
        if (record.repeat_count < MIN_REPEAT_COUNT) continue;
        try payload.append(record.token_count);
        for (record.tokens[0..record.token_count]) |token_id| {
            try appendWord(&payload, model.tokens.items[token_id]);
        }
        try appendInt(&payload, u32, record.repeat_count);
        try appendInt(&payload, u32, record.shown_count);
        try appendInt(&payload, u32, record.accepted_count);
        try appendInt(&payload, u64, record.last_used);
        try appendInt(&payload, u16, record.consecutive_ignores);
        persisted_count += 1;
    }

    var output = try std.ArrayList(u8).initCapacity(allocator, PROFILE_HEADER_SIZE + payload.items.len);
    errdefer output.deinit();
    try output.appendSlice(PROFILE_MAGIC);
    try appendInt(&output, u16, PROFILE_VERSION);
    try appendInt(&output, u32, persisted_count);
    try appendInt(&output, u32, @intCast(payload.items.len));
    try appendInt(&output, u32, std.hash.Crc32.hash(payload.items));
    try output.appendSlice(payload.items);
    return output.toOwnedSlice();
}

pub fn decodeProfileInto(model: *SentenceModel, bytes: []const u8) !void {
    if (bytes.len < PROFILE_HEADER_SIZE or bytes.len > MAX_PROFILE_SIZE) return error.InvalidSentenceProfile;
    if (!std.mem.eql(u8, bytes[0..PROFILE_MAGIC.len], PROFILE_MAGIC)) return error.InvalidSentenceProfile;
    var offset: usize = PROFILE_MAGIC.len;
    if (try readInt(u16, bytes, &offset) != PROFILE_VERSION) return error.UnsupportedSentenceProfile;
    const count = try readInt(u32, bytes, &offset);
    if (count > MAX_SENTENCE_RECORDS) return error.InvalidSentenceProfile;
    const payload_len = try readInt(u32, bytes, &offset);
    const checksum = try readInt(u32, bytes, &offset);
    if (payload_len != bytes.len - PROFILE_HEADER_SIZE or std.hash.Crc32.hash(bytes[PROFILE_HEADER_SIZE..]) != checksum) {
        return error.InvalidSentenceProfile;
    }

    var records = std.ArrayList(StoredRecord).init(model.allocator);
    defer records.deinit();
    offset = PROFILE_HEADER_SIZE;
    for (0..count) |_| {
        if (offset >= bytes.len) return error.InvalidSentenceProfile;
        var record = StoredRecord{
            .tokens = undefined,
            .token_count = bytes[offset],
            .repeat_count = 0,
            .shown_count = 0,
            .accepted_count = 0,
            .last_used = 0,
            .consecutive_ignores = 0,
        };
        offset += 1;
        if (record.token_count < MIN_SENTENCE_WORDS or record.token_count > MAX_SENTENCE_TOKENS) return error.InvalidSentenceProfile;
        for (0..record.token_count) |index| {
            record.tokens[index] = try readWord(bytes, &offset);
            var normalized: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined;
            const checked = normalizeToken(record.tokens[index], &normalized) orelse return error.InvalidSentenceProfile;
            _ = checked;
        }
        record.repeat_count = try readInt(u32, bytes, &offset);
        record.shown_count = try readInt(u32, bytes, &offset);
        record.accepted_count = try readInt(u32, bytes, &offset);
        record.last_used = try readInt(u64, bytes, &offset);
        record.consecutive_ignores = try readInt(u16, bytes, &offset);
        if (record.repeat_count < MIN_REPEAT_COUNT) return error.InvalidSentenceProfile;
        try records.append(record);
    }
    if (offset != bytes.len) return error.InvalidSentenceProfile;
    for (records.items) |record| try model.restoreRecord(record);
}

fn isWordChar(character: u8) bool {
    return insertion.isWordChar(character);
}

fn isSoftPunctuation(character: u8) bool {
    return character == ',' or character == ';' or character == ':';
}

fn isHardBoundary(character: u8) bool {
    return character == '.' or character == '!' or character == '?' or character == '\n' or character == '\r';
}

fn isPunctuationToken(token: []const u8) bool {
    return token.len == 1 and isSoftPunctuation(token[0]);
}

fn normalizeToken(token: []const u8, storage: []u8) ?[]const u8 {
    if (token.len == 0 or token.len > storage.len) return null;
    if (isPunctuationToken(token)) {
        storage[0] = token[0];
        return storage[0..1];
    }
    for (token, 0..) |character, index| {
        if (!isWordChar(character)) return null;
        storage[index] = std.ascii.toLower(character);
    }
    return storage[0..token.len];
}

fn firstWordsKey(token_ids: []const u32, tokens: []const []const u8) ?FirstWordsKey {
    var key: FirstWordsKey = undefined;
    var count: usize = 0;
    for (token_ids) |token_id| {
        if (isPunctuationToken(tokens[token_id])) continue;
        key.ids[count] = token_id;
        count += 1;
        if (count == MIN_SENTENCE_WORDS) return key;
    }
    return null;
}

fn confidenceFor(record: SentenceRecord) u16 {
    const repetition = @min(@as(u64, 250), @as(u64, record.repeat_count) * 100);
    const acceptance = @min(@as(u64, 150), @as(u64, record.accepted_count) * 30);
    const ignore_penalty = @min(@as(u64, 600), @as(u64, record.consecutive_ignores) * 30);
    return @intCast(@min(@as(u64, 1000), @as(u64, 650) + repetition + acceptance) -| ignore_penalty);
}

fn scoreFor(clock: u64, record: SentenceRecord, confidence: u16) i32 {
    const age = clock -| record.last_used;
    const recency: i32 = @intCast(500 - @min(age, 500));
    const accepted: i32 = @intCast(@min(record.accepted_count, 1000));
    return @as(i32, confidence) * 10 + accepted * 100 + recency;
}

fn buildPrediction(
    model: *const SentenceModel,
    record_index: u16,
    record: SentenceRecord,
    confidence: u16,
) ?Prediction {
    var prediction = Prediction{
        .score = scoreFor(model.usage_clock, record, confidence),
        .confidence = confidence,
        .record_index = record_index,
    };
    var output_len: usize = 0;
    var predicted_words: usize = 0;
    var chunk_start: usize = 0;
    var chunk_words: usize = 0;

    for (record.tokens[model.current_count..record.token_count]) |token_id| {
        const token = model.tokens.items[token_id];
        if (isPunctuationToken(token)) {
            if (output_len == 0) continue;
            if (output_len + token.len > prediction.text.len) break;
            @memcpy(prediction.text[output_len .. output_len + token.len], token);
            output_len += token.len;
            closeChunk(&prediction, chunk_start, output_len, chunk_words);
            chunk_start = output_len;
            chunk_words = 0;
            continue;
        }
        if (predicted_words >= MAX_PREDICTED_WORDS) break;
        if (chunk_words >= 4) {
            closeChunk(&prediction, chunk_start, output_len, chunk_words);
            chunk_start = output_len;
            chunk_words = 0;
        }
        const separator_len: usize = if (output_len == 0) 0 else 1;
        if (output_len + separator_len + token.len > prediction.text.len) break;
        if (separator_len != 0) prediction.text[output_len] = ' ';
        @memcpy(prediction.text[output_len + separator_len .. output_len + separator_len + token.len], token);
        output_len += separator_len + token.len;
        predicted_words += 1;
        chunk_words += 1;
    }
    closeChunk(&prediction, chunk_start, output_len, chunk_words);
    if (output_len == 0 or prediction.chunk_count == 0) return null;
    prediction.len = @intCast(output_len);
    return prediction;
}

fn closeChunk(prediction: *Prediction, start: usize, end: usize, word_count: usize) void {
    if (end <= start or word_count == 0 or prediction.chunk_count >= prediction.chunks.len) return;
    prediction.chunks[prediction.chunk_count] = .{
        .start = @intCast(start),
        .len = @intCast(end - start),
        .kind = if (word_count == 1) .word else .phrase,
    };
    prediction.chunk_count += 1;
}

fn insertPrediction(set: *PredictionSet, candidate: *const Prediction) void {
    var destination: usize = set.count;
    if (set.count < set.items.len) {
        set.items[set.count] = candidate.*;
        set.count += 1;
    } else {
        destination = set.items.len - 1;
        if (!predictionBetter(candidate, &set.items[destination])) return;
        set.items[destination] = candidate.*;
    }
    while (destination > 0 and predictionBetter(&set.items[destination], &set.items[destination - 1])) {
        const temporary = set.items[destination - 1];
        set.items[destination - 1] = set.items[destination];
        set.items[destination] = temporary;
        destination -= 1;
    }
}

fn predictionBetter(left: *const Prediction, right: *const Prediction) bool {
    if (left.score != right.score) return left.score > right.score;
    return std.mem.order(u8, left.textSlice(), right.textSlice()) == .lt;
}

fn weakestInBucket(model: *const SentenceModel, bucket: *const RecordBucket) usize {
    var selected: usize = bucket.indices[0];
    for (bucket.indices[1..bucket.count]) |index| {
        if (weaker(model.records.items[index], model.records.items[selected])) selected = index;
    }
    return selected;
}

fn weaker(left: SentenceRecord, right: SentenceRecord) bool {
    const left_value = @as(u128, left.accepted_count) * 1_000_000 +
        @as(u128, left.repeat_count) * 1_000 + left.last_used;
    const right_value = @as(u128, right.accepted_count) * 1_000_000 +
        @as(u128, right.repeat_count) * 1_000 + right.last_used;
    return left_value < right_value;
}

fn appendWord(payload: *std.ArrayList(u8), word: []const u8) !void {
    if (word.len == 0 or word.len > config.TEXT.MAX_SUGGESTION_LEN) return error.InvalidSentenceProfile;
    try appendInt(payload, u16, @intCast(word.len));
    try payload.appendSlice(word);
}

fn appendInt(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(&bytes);
}

fn readInt(comptime T: type, bytes: []const u8, offset: *usize) !T {
    if (offset.* + @sizeOf(T) > bytes.len) return error.InvalidSentenceProfile;
    const value = std.mem.readInt(T, bytes[offset.*..][0..@sizeOf(T)], .little);
    offset.* += @sizeOf(T);
    return value;
}

fn readWord(bytes: []const u8, offset: *usize) ![]const u8 {
    const length = try readInt(u16, bytes, offset);
    if (length == 0 or length > config.TEXT.MAX_SUGGESTION_LEN or offset.* + length > bytes.len) {
        return error.InvalidSentenceProfile;
    }
    const word = bytes[offset.* .. offset.* + length];
    offset.* += length;
    return word;
}
