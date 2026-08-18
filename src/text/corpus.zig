const std = @import("std");

pub const MAX_CORPORA: usize = 32;
pub const MAX_PATH_BYTES: usize = 520;
pub const MAX_NAME_BYTES: usize = 96;
pub const MAX_TOKENS: usize = 30_000;
pub const MAX_CONTEXTS: usize = 60_000;
pub const MAX_CONTEXT_WORDS: usize = 5;
pub const MIN_CONTEXT_WORDS: usize = 2;
pub const MAX_CONTINUATIONS: usize = 3;
pub const MAX_FILE_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_INDEX_BYTES: usize = 32 * 1024 * 1024;
pub const WM_CORPUS_CHANGED: u32 = 0x8000 + 30;

const INDEX_MAGIC = "SYSICRP1";
const INDEX_VERSION: u16 = 1;
const INDEX_HEADER: usize = 8 + 2 + 4 + 4;
const MANIFEST_MAGIC = "SYSICRM1";
const MANIFEST_VERSION: u16 = 1;
const MANIFEST_HEADER: usize = 8 + 2 + 4 + 4;

pub const Status = enum(u8) { indexing, ready, failed, cancelled };

pub const Metadata = struct {
    id: u32 = 0,
    name: [MAX_NAME_BYTES]u8 = undefined,
    name_len: u8 = 0,
    source: [MAX_PATH_BYTES]u8 = undefined,
    source_len: u16 = 0,
    is_folder: bool = false,
    enabled: bool = true,
    file_count: u32 = 0,
    indexed_at: i64 = 0,
    status: Status = .indexing,

    pub fn nameSlice(self: *const Metadata) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn sourceSlice(self: *const Metadata) []const u8 {
        return self.source[0..self.source_len];
    }
};

const ContextKey = struct { ids: [MAX_CONTEXT_WORDS]u32 = [_]u32{0} ** MAX_CONTEXT_WORDS, len: u8 = 0 };
const Continuation = struct { token_id: u32, count: u32 };
const Bucket = struct {
    items: [MAX_CONTINUATIONS]Continuation = undefined,
    count: u8 = 0,
    fn total(self: *const Bucket) u64 {
        var value: u64 = 0;
        for (self.items[0..self.count]) |item| value += item.count;
        return value;
    }
};

pub const PredictionKind = enum(u8) { word, next_word, phrase, sentence };
pub const Prediction = struct {
    text: [256]u8 = undefined,
    len: u16 = 0,
    kind: PredictionKind = .next_word,
    score: i32 = 0,
    confidence: u16 = 0,
    pub fn slice(self: *const Prediction) []const u8 {
        return self.text[0..self.len];
    }
};
pub const PredictionSet = struct {
    items: [5]Prediction = undefined,
    count: u8 = 0,
    pub fn slice(self: *const PredictionSet) []const Prediction {
        return self.items[0..self.count];
    }
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    token_ids: std.StringHashMap(u32),
    tokens: std.ArrayList([]const u8),
    frequencies: std.ArrayList(u32),
    sorted_ids: std.ArrayList(u32),
    contexts: std.AutoHashMap(ContextKey, Bucket),

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator, .token_ids = std.StringHashMap(u32).init(allocator), .tokens = std.ArrayList([]const u8).init(allocator), .frequencies = std.ArrayList(u32).init(allocator), .sorted_ids = std.ArrayList(u32).init(allocator), .contexts = std.AutoHashMap(ContextKey, Bucket).init(allocator) };
    }
    pub fn deinit(self: *Index) void {
        for (self.tokens.items) |token| self.allocator.free(token);
        self.token_ids.deinit();
        self.tokens.deinit();
        self.frequencies.deinit();
        self.sorted_ids.deinit();
        self.contexts.deinit();
    }

    pub fn ingest(self: *Index, text: []const u8, cancel: *const std.atomic.Value(bool)) !void {
        var history: [MAX_CONTEXT_WORDS]u32 = undefined;
        var history_count: usize = 0;
        var word: [64]u8 = undefined;
        var word_len: usize = 0;
        for (text, 0..) |character, offset| {
            if (offset % 16_384 == 0 and cancel.load(.acquire)) return error.Cancelled;
            if (isWordChar(character)) {
                if (word_len < word.len) {
                    word[word_len] = std.ascii.toLower(character);
                    word_len += 1;
                }
                continue;
            }
            if (word_len > 0) {
                try self.observeWord(word[0..word_len], &history, &history_count);
                word_len = 0;
            }
            if (character == '.' or character == '!' or character == '?' or character == '\n') history_count = 0;
        }
        if (word_len > 0) try self.observeWord(word[0..word_len], &history, &history_count);
    }

    fn observeWord(self: *Index, word: []const u8, history: *[MAX_CONTEXT_WORDS]u32, history_count: *usize) !void {
        if (word.len == 0) return;
        const token_id = try self.intern(word) orelse {
            history_count.* = 0;
            return;
        };
        self.frequencies.items[token_id] +|= 1;
        const maximum = @min(history_count.*, MAX_CONTEXT_WORDS);
        var context_len: usize = MIN_CONTEXT_WORDS;
        while (context_len <= maximum) : (context_len += 1) {
            var key = ContextKey{ .len = @intCast(context_len) };
            @memcpy(key.ids[0..context_len], history[history_count.* - context_len .. history_count.*]);
            if (self.contexts.getPtr(key)) |bucket| {
                addContinuation(bucket, token_id);
            } else if (self.contexts.count() < MAX_CONTEXTS) {
                try self.contexts.put(key, .{});
                addContinuation(self.contexts.getPtr(key).?, token_id);
            }
        }
        if (history_count.* < MAX_CONTEXT_WORDS) {
            history[history_count.*] = token_id;
            history_count.* += 1;
        } else {
            std.mem.copyForwards(u32, history[0 .. MAX_CONTEXT_WORDS - 1], history[1..MAX_CONTEXT_WORDS]);
            history[MAX_CONTEXT_WORDS - 1] = token_id;
        }
    }

    fn intern(self: *Index, word: []const u8) !?u32 {
        if (self.token_ids.get(word)) |id| return id;
        if (self.tokens.items.len >= MAX_TOKENS) return null;
        const owned = try self.allocator.dupe(u8, word);
        errdefer self.allocator.free(owned);
        const id: u32 = @intCast(self.tokens.items.len);
        try self.tokens.append(owned);
        errdefer _ = self.tokens.pop();
        try self.frequencies.append(0);
        errdefer _ = self.frequencies.pop();
        try self.token_ids.put(owned, id);
        return id;
    }

    pub fn finish(self: *Index) !void {
        self.sorted_ids.clearRetainingCapacity();
        try self.sorted_ids.ensureTotalCapacity(self.tokens.items.len);
        for (0..self.tokens.items.len) |index| self.sorted_ids.appendAssumeCapacity(@intCast(index));
        std.mem.sort(u32, self.sorted_ids.items, self, lessToken);
    }

    pub fn predict(self: *const Index, text: []const u8, current_word: []const u8, penalty: u16) PredictionSet {
        if (current_word.len > 0) return self.predictWords(current_word, penalty);
        var history_words: [MAX_CONTEXT_WORDS][64]u8 = undefined;
        var history_lens: [MAX_CONTEXT_WORDS]u8 = [_]u8{0} ** MAX_CONTEXT_WORDS;
        const count = extractHistory(text, &history_words, &history_lens);
        if (count < MIN_CONTEXT_WORDS) return .{};
        var ids: [MAX_CONTEXT_WORDS]u32 = undefined;
        for (0..count) |index| ids[index] = self.token_ids.get(history_words[index][0..history_lens[index]]) orelse return .{};
        var context_len = @min(count, MAX_CONTEXT_WORDS);
        while (context_len >= MIN_CONTEXT_WORDS) : (context_len -= 1) {
            var key = ContextKey{ .len = @intCast(context_len) };
            @memcpy(key.ids[0..context_len], ids[count - context_len .. count]);
            if (self.contexts.get(key)) |bucket| return self.predictContext(key, bucket, penalty);
            if (context_len == MIN_CONTEXT_WORDS) break;
        }
        return .{};
    }

    fn predictWords(self: *const Index, prefix_raw: []const u8, penalty: u16) PredictionSet {
        var prefix: [64]u8 = undefined;
        if (prefix_raw.len == 0 or prefix_raw.len > prefix.len) return .{};
        for (prefix_raw, 0..) |c, i| prefix[i] = std.ascii.toLower(c);
        const needle = prefix[0..prefix_raw.len];
        var low: usize = 0;
        var high = self.sorted_ids.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (std.mem.order(u8, self.tokens.items[self.sorted_ids.items[mid]], needle) == .lt) low = mid + 1 else high = mid;
        }
        var result = PredictionSet{};
        var index = low;
        while (index < self.sorted_ids.items.len) : (index += 1) {
            const id = self.sorted_ids.items[index];
            const token = self.tokens.items[id];
            if (!std.mem.startsWith(u8, token, needle)) break;
            if (token.len == needle.len) continue;
            var prediction = Prediction{ .kind = .word, .score = @as(i32, @intCast(@min(self.frequencies.items[id], 100_000))) * 4 - penalty, .confidence = @intCast(@min(950, 450 + self.frequencies.items[id] * 20)) };
            if (token.len > prediction.text.len) continue;
            @memcpy(prediction.text[0..token.len], token);
            prediction.len = @intCast(token.len);
            insertPrediction(&result, prediction);
        }
        return result;
    }

    fn predictContext(self: *const Index, initial_key: ContextKey, initial_bucket: Bucket, penalty: u16) PredictionSet {
        const best = bestContinuation(initial_bucket) orelse return .{};
        const total = initial_bucket.total();
        if (best.count < 2 or total == 0) return .{};
        const confidence: u16 = @intCast(@min(1000, best.count * 1000 / total));
        const ambiguous_initial = isAmbiguous(initial_bucket, best);
        if (confidence < (if (ambiguous_initial) @as(u16, 500) else 600)) return .{};
        var prediction = Prediction{ .score = @as(i32, @intCast(best.count * 20)) + confidence - penalty, .confidence = confidence };
        var history = initial_key.ids;
        var history_count: usize = initial_key.len;
        var token = best.token_id;
        var words: usize = 0;
        while (words < 12) : (words += 1) {
            const value = self.tokens.items[token];
            if (!appendWord(&prediction, value)) break;
            if (history_count < MAX_CONTEXT_WORDS) {
                history[history_count] = token;
                history_count += 1;
            } else {
                std.mem.copyForwards(u32, history[0 .. MAX_CONTEXT_WORDS - 1], history[1..MAX_CONTEXT_WORDS]);
                history[MAX_CONTEXT_WORDS - 1] = token;
            }
            if (ambiguous_initial) break;
            var key = ContextKey{ .len = @intCast(history_count) };
            @memcpy(key.ids[0..history_count], history[0..history_count]);
            const bucket = self.contexts.get(key) orelse break;
            const next = bestContinuation(bucket) orelse break;
            const bucket_total = bucket.total();
            if (next.count < 2 or bucket_total == 0) break;
            const next_confidence: u16 = @intCast(@min(1000, next.count * 1000 / bucket_total));
            if (next_confidence < 850 or isAmbiguous(bucket, next)) break;
            prediction.confidence = @min(prediction.confidence, next_confidence);
            token = next.token_id;
        }
        const word_count = words + 1;
        prediction.kind = if (word_count == 1) .next_word else if (word_count <= 4) .phrase else .sentence;
        return .{ .items = blk: {
            var items: [5]Prediction = undefined;
            items[0] = prediction;
            break :blk items;
        }, .count = 1 };
    }
};

const Record = struct { metadata: Metadata, index: ?*Index = null };
const Operation = enum { import_path, rebuild, remove, toggle };
const Job = struct { service: *Service, operation: Operation, id: u32, source: [MAX_PATH_BYTES]u8 = undefined, source_len: u16 = 0, is_folder: bool = false };

pub const Service = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    manifest_path: []u8,
    records: std.ArrayList(Record),
    mutex: std.Thread.Mutex = .{},
    worker: ?std.Thread = null,
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    progress: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    notify_window: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    next_id: u32 = 1,
    penalties: std.StringHashMap(u16),

    pub fn initAt(allocator: std.mem.Allocator, directory: []const u8) !Service {
        try std.fs.cwd().makePath(directory);
        var result = Service{ .allocator = allocator, .directory = try allocator.dupe(u8, directory), .manifest_path = try std.fs.path.join(allocator, &.{ directory, "manifest.bin" }), .records = std.ArrayList(Record).init(allocator), .penalties = std.StringHashMap(u16).init(allocator) };
        errdefer result.deinit();
        result.loadManifest() catch {};
        return result;
    }
    pub fn deinit(self: *Service) void {
        self.cancel.store(true, .release);
        if (self.worker) |thread| thread.join();
        self.worker = null;
        for (self.records.items) |*record| if (record.index) |index| {
            index.deinit();
            self.allocator.destroy(index);
        };
        var iterator = self.penalties.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.penalties.deinit();
        self.records.deinit();
        self.allocator.free(self.directory);
        self.allocator.free(self.manifest_path);
    }
    pub fn setNotifyWindow(self: *Service, window: ?*anyopaque) void {
        self.notify_window.store(if (window) |handle| @intFromPtr(handle) else 0, .release);
    }
    pub fn isBusy(self: *const Service) bool {
        return self.busy.load(.acquire);
    }
    pub fn progressValue(self: *const Service) u8 {
        return self.progress.load(.acquire);
    }
    pub fn requestCancel(self: *Service) void {
        self.cancel.store(true, .release);
    }

    pub fn startImport(self: *Service, source: []const u8, is_folder: bool) !void {
        if (source.len == 0 or source.len > MAX_PATH_BYTES) return error.InvalidCorpusPath;
        self.reap();
        if (self.busy.swap(true, .acq_rel)) return error.CorpusBusy;
        self.mutex.lock();
        const at_capacity = self.records.items.len >= MAX_CORPORA;
        self.mutex.unlock();
        if (at_capacity) {
            self.busy.store(false, .release);
            return error.TooManyCorpora;
        }
        self.cancel.store(false, .release);
        self.progress.store(0, .release);
        const id = self.next_id;
        self.next_id +%= 1;
        var metadata = Metadata{ .id = id, .is_folder = is_folder, .status = .indexing };
        setMetadataText(&metadata, source);
        self.mutex.lock();
        self.records.append(.{ .metadata = metadata }) catch |err| {
            self.mutex.unlock();
            self.busy.store(false, .release);
            return err;
        };
        self.mutex.unlock();
        const job = self.allocator.create(Job) catch |err| {
            self.busy.store(false, .release);
            return err;
        };
        job.* = .{ .service = self, .operation = .import_path, .id = id, .source_len = @intCast(source.len), .is_folder = is_folder };
        @memcpy(job.source[0..source.len], source);
        self.worker = std.Thread.spawn(.{}, runJob, .{job}) catch |err| {
            self.allocator.destroy(job);
            self.busy.store(false, .release);
            return err;
        };
        self.notify();
    }
    pub fn startRebuild(self: *Service, id: u32) !void {
        try self.startRecordJob(.rebuild, id);
    }
    pub fn startRemove(self: *Service, id: u32) !void {
        try self.startRecordJob(.remove, id);
    }
    pub fn startToggle(self: *Service, id: u32) !void {
        try self.startRecordJob(.toggle, id);
    }
    fn startRecordJob(self: *Service, operation: Operation, id: u32) !void {
        self.reap();
        if (self.busy.swap(true, .acq_rel)) return error.CorpusBusy;
        self.cancel.store(false, .release);
        self.progress.store(0, .release);
        const job = self.allocator.create(Job) catch |err| {
            self.busy.store(false, .release);
            return err;
        };
        job.* = .{ .service = self, .operation = operation, .id = id };
        self.worker = std.Thread.spawn(.{}, runJob, .{job}) catch |err| {
            self.allocator.destroy(job);
            self.busy.store(false, .release);
            return err;
        };
    }
    fn reap(self: *Service) void {
        if (!self.busy.load(.acquire)) if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        };
    }

    pub fn copyMetadata(self: *Service, output: *[MAX_CORPORA]Metadata) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(output.len, self.records.items.len);
        for (self.records.items[0..count], 0..) |record, index| output[index] = record.metadata;
        return count;
    }

    pub fn predict(self: *Service, text: []const u8, current_word: []const u8) PredictionSet {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result = PredictionSet{};
        for (self.records.items) |*record| {
            if (!record.metadata.enabled or record.metadata.status != .ready) continue;
            const index = record.index orelse continue;
            const set = index.predict(text, current_word, 0);
            for (set.slice()) |prediction| {
                const penalty = self.penalties.get(prediction.slice()) orelse 0;
                if (penalty >= 200) continue;
                var adjusted = prediction;
                adjusted.score -= penalty;
                insertPrediction(&result, adjusted);
            }
        }
        return result;
    }
    pub fn recordFeedback(self: *Service, shown: bool, text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (shown) {
            if (self.penalties.getPtr(text)) |value| value.* +|= 20 else {
                const owned = try self.allocator.dupe(u8, text);
                errdefer self.allocator.free(owned);
                try self.penalties.put(owned, 20);
            }
        } else if (self.penalties.getPtr(text)) |value| value.* = 0;
    }

    fn notify(self: *Service) void {
        const value = self.notify_window.load(.acquire);
        if (value != 0) _ = postMessage(@ptrFromInt(value), WM_CORPUS_CHANGED);
    }
    fn indexPath(self: *Service, id: u32, temporary: bool) ![:0]u8 {
        return std.fmt.allocPrintZ(self.allocator, "{s}\\corpus-{d}.idx{s}", .{ self.directory, id, if (temporary) ".tmp" else "" });
    }

    fn loadManifest(self: *Service) !void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.manifest_path, 256 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        if (bytes.len < MANIFEST_HEADER or !std.mem.eql(u8, bytes[0..8], MANIFEST_MAGIC) or std.mem.readInt(u16, bytes[8..10], .little) != MANIFEST_VERSION) return error.InvalidCorpusManifest;
        const length = std.mem.readInt(u32, bytes[10..14], .little);
        if (bytes.len != MANIFEST_HEADER + length or std.hash.Crc32.hash(bytes[MANIFEST_HEADER..]) != std.mem.readInt(u32, bytes[14..18], .little)) return error.InvalidCorpusManifest;
        const payload = bytes[MANIFEST_HEADER..];
        if (payload.len < 6) return error.InvalidCorpusManifest;
        self.next_id = std.mem.readInt(u32, payload[0..4], .little);
        const count = std.mem.readInt(u16, payload[4..6], .little);
        if (count > MAX_CORPORA) return error.InvalidCorpusManifest;
        var offset: usize = 6;
        for (0..count) |_| {
            if (offset + 22 > payload.len) return error.InvalidCorpusManifest;
            var metadata = Metadata{ .id = std.mem.readInt(u32, payload[offset..][0..4], .little), .enabled = payload[offset + 4] != 0, .is_folder = payload[offset + 5] != 0, .status = @enumFromInt(payload[offset + 6]), .file_count = std.mem.readInt(u32, payload[offset + 7 ..][0..4], .little), .indexed_at = std.mem.readInt(i64, payload[offset + 11 ..][0..8], .little), .name_len = payload[offset + 19], .source_len = std.mem.readInt(u16, payload[offset + 20 ..][0..2], .little) };
            offset += 22;
            if (metadata.name_len > MAX_NAME_BYTES or metadata.source_len > MAX_PATH_BYTES or offset + metadata.name_len + metadata.source_len > payload.len) return error.InvalidCorpusManifest;
            @memcpy(metadata.name[0..metadata.name_len], payload[offset..][0..metadata.name_len]);
            offset += metadata.name_len;
            @memcpy(metadata.source[0..metadata.source_len], payload[offset..][0..metadata.source_len]);
            offset += metadata.source_len;
            var record = Record{ .metadata = metadata };
            if (metadata.status == .ready) {
                const path = try self.indexPath(metadata.id, false);
                defer self.allocator.free(path);
                const index = try self.allocator.create(Index);
                index.* = Index.init(self.allocator);
                if (loadIndex(index, path)) |_| record.index = index else |_| {
                    index.deinit();
                    self.allocator.destroy(index);
                    record.metadata.status = .failed;
                }
            }
            try self.records.append(record);
        }
    }

    fn saveManifest(self: *Service) !void {
        self.mutex.lock();
        var snapshot: [MAX_CORPORA]Metadata = undefined;
        const snapshot_count = self.records.items.len;
        const snapshot_next_id = self.next_id;
        for (self.records.items, 0..) |record, index| snapshot[index] = record.metadata;
        self.mutex.unlock();
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        try payload.writer().writeInt(u32, snapshot_next_id, .little);
        try payload.writer().writeInt(u16, @intCast(snapshot_count), .little);
        for (snapshot[0..snapshot_count]) |*metadata| {
            try payload.writer().writeInt(u32, metadata.id, .little);
            try payload.append(@intFromBool(metadata.enabled));
            try payload.append(@intFromBool(metadata.is_folder));
            try payload.append(@intFromEnum(metadata.status));
            try payload.writer().writeInt(u32, metadata.file_count, .little);
            try payload.writer().writeInt(i64, metadata.indexed_at, .little);
            try payload.append(metadata.name_len);
            try payload.writer().writeInt(u16, metadata.source_len, .little);
            try payload.appendSlice(metadata.nameSlice());
            try payload.appendSlice(metadata.sourceSlice());
        }
        const temporary = try std.fmt.allocPrintZ(self.allocator, "{s}.tmp", .{self.manifest_path});
        defer self.allocator.free(temporary);
        var file = try std.fs.cwd().createFile(temporary, .{ .truncate = true });
        var open = true;
        defer if (open) file.close();
        errdefer std.fs.cwd().deleteFile(temporary) catch {};
        try file.writeAll(MANIFEST_MAGIC);
        try file.writer().writeInt(u16, MANIFEST_VERSION, .little);
        try file.writer().writeInt(u32, @intCast(payload.items.len), .little);
        try file.writer().writeInt(u32, std.hash.Crc32.hash(payload.items), .little);
        try file.writeAll(payload.items);
        try file.sync();
        file.close();
        open = false;
        const manifest_z = try self.allocator.dupeZ(u8, self.manifest_path);
        defer self.allocator.free(manifest_z);
        if (MoveFileExA(temporary.ptr, manifest_z.ptr, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0) return error.CorpusManifestReplaceFailed;
    }
};

fn runJob(job: *Job) void {
    const service = job.service;
    defer service.allocator.destroy(job);
    defer {
        service.busy.store(false, .release);
        service.progress.store(100, .release);
        service.notify();
    }
    switch (job.operation) {
        .import_path, .rebuild => buildJob(job) catch |err| markBuildFailure(service, job.id, if (err == error.Cancelled) .cancelled else .failed),
        .remove => removeJob(service, job.id),
        .toggle => toggleJob(service, job.id),
    }
    service.saveManifest() catch {};
}

fn buildJob(job: *Job) !void {
    const service = job.service;
    var source_storage: [MAX_PATH_BYTES]u8 = undefined;
    var source: []const u8 = undefined;
    var is_folder = job.is_folder;
    if (job.operation == .import_path) {
        @memcpy(source_storage[0..job.source_len], job.source[0..job.source_len]);
        source = source_storage[0..job.source_len];
    } else {
        service.mutex.lock();
        defer service.mutex.unlock();
        const record = findRecord(service, job.id) orelse return error.CorpusNotFound;
        const value = record.metadata.sourceSlice();
        @memcpy(source_storage[0..value.len], value);
        source = source_storage[0..value.len];
        is_folder = record.metadata.is_folder;
        record.metadata.status = .indexing;
    }
    var index = try service.allocator.create(Index);
    index.* = Index.init(service.allocator);
    errdefer {
        index.deinit();
        service.allocator.destroy(index);
    }
    var file_count: u32 = 0;
    if (is_folder) try ingestFolder(index, source, service, &file_count) else {
        try ingestFile(index, source, &service.cancel);
        file_count = 1;
        service.progress.store(80, .release);
        service.notify();
    }
    if (service.cancel.load(.acquire)) return error.Cancelled;
    try index.finish();
    service.progress.store(90, .release);
    const temporary = try service.indexPath(job.id, true);
    defer service.allocator.free(temporary);
    errdefer std.fs.cwd().deleteFile(temporary) catch {};
    const final = try service.indexPath(job.id, false);
    defer service.allocator.free(final);
    try saveIndex(index, temporary);
    if (MoveFileExA(temporary.ptr, final.ptr, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0) return error.CorpusIndexReplaceFailed;
    service.mutex.lock();
    const record = findRecord(service, job.id) orelse {
        service.mutex.unlock();
        return error.CorpusNotFound;
    };
    if (record.index) |old| {
        old.deinit();
        service.allocator.destroy(old);
    }
    record.index = index;
    record.metadata.file_count = file_count;
    record.metadata.indexed_at = std.time.milliTimestamp();
    record.metadata.status = .ready;
    service.mutex.unlock();
}

fn removeJob(service: *Service, id: u32) void {
    service.mutex.lock();
    var found: ?usize = null;
    for (service.records.items, 0..) |record, index| if (record.metadata.id == id) {
        found = index;
        break;
    };
    if (found) |index| {
        const record = service.records.orderedRemove(index);
        if (record.index) |value| {
            value.deinit();
            service.allocator.destroy(value);
        }
    }
    service.mutex.unlock();
    if (service.indexPath(id, false)) |path| {
        defer service.allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    } else |_| {}
}
fn toggleJob(service: *Service, id: u32) void {
    service.mutex.lock();
    if (findRecord(service, id)) |record| record.metadata.enabled = !record.metadata.enabled;
    service.mutex.unlock();
}
fn markBuildFailure(service: *Service, id: u32, status: Status) void {
    service.mutex.lock();
    if (findRecord(service, id)) |record| record.metadata.status = if (record.index != null) .ready else status;
    service.mutex.unlock();
}

fn ingestFile(index: *Index, path: []const u8, cancel: *const std.atomic.Value(bool)) !void {
    if (!supportedPath(path)) return error.UnsupportedCorpusFile;
    const contents = try std.fs.cwd().readFileAlloc(index.allocator, path, MAX_FILE_BYTES);
    defer index.allocator.free(contents);
    try index.ingest(contents, cancel);
}
fn ingestFolder(index: *Index, root: []const u8, service: *Service, count: *u32) !void {
    var directory = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer directory.close();
    var walker = try directory.walk(index.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (service.cancel.load(.acquire)) return error.Cancelled;
        if (entry.kind != .file or !supportedPath(entry.path)) continue;
        const full = try std.fs.path.join(index.allocator, &.{ root, entry.path });
        defer index.allocator.free(full);
        ingestFile(index, full, &service.cancel) catch |err| switch (err) {
            error.FileTooBig => continue,
            else => return err,
        };
        count.* +|= 1;
        service.progress.store(@intCast(@min(80, count.*)), .release);
        service.notify();
    }
    if (count.* == 0) return error.NoCorpusFiles;
}

fn saveIndex(index: *Index, path: []const u8) !void {
    var payload = std.ArrayList(u8).init(index.allocator);
    defer payload.deinit();
    try payload.writer().writeInt(u32, @intCast(index.tokens.items.len), .little);
    for (index.tokens.items, 0..) |token, id| {
        try payload.writer().writeInt(u16, @intCast(token.len), .little);
        try payload.writer().writeInt(u32, index.frequencies.items[id], .little);
        try payload.appendSlice(token);
    }
    try payload.writer().writeInt(u32, @intCast(index.contexts.count()), .little);
    var iterator = index.contexts.iterator();
    while (iterator.next()) |entry| {
        try payload.append(entry.key_ptr.len);
        for (entry.key_ptr.ids[0..entry.key_ptr.len]) |id| try payload.writer().writeInt(u32, id, .little);
        try payload.append(entry.value_ptr.count);
        for (entry.value_ptr.items[0..entry.value_ptr.count]) |item| {
            try payload.writer().writeInt(u32, item.token_id, .little);
            try payload.writer().writeInt(u32, item.count, .little);
        }
    }
    if (payload.items.len > MAX_INDEX_BYTES) return error.CorpusIndexTooLarge;
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(INDEX_MAGIC);
    try file.writer().writeInt(u16, INDEX_VERSION, .little);
    try file.writer().writeInt(u32, @intCast(payload.items.len), .little);
    try file.writer().writeInt(u32, std.hash.Crc32.hash(payload.items), .little);
    try file.writeAll(payload.items);
    try file.sync();
}

fn loadIndex(index: *Index, path: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(index.allocator, path, MAX_INDEX_BYTES + INDEX_HEADER);
    defer index.allocator.free(bytes);
    if (bytes.len < INDEX_HEADER or !std.mem.eql(u8, bytes[0..8], INDEX_MAGIC) or std.mem.readInt(u16, bytes[8..10], .little) != INDEX_VERSION) return error.InvalidCorpusIndex;
    const length = std.mem.readInt(u32, bytes[10..14], .little);
    if (bytes.len != INDEX_HEADER + length or std.hash.Crc32.hash(bytes[INDEX_HEADER..]) != std.mem.readInt(u32, bytes[14..18], .little)) return error.InvalidCorpusIndex;
    const payload = bytes[INDEX_HEADER..];
    if (payload.len < 4) return error.InvalidCorpusIndex;
    var offset: usize = 0;
    const token_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
    offset += 4;
    if (token_count > MAX_TOKENS) return error.InvalidCorpusIndex;
    try index.tokens.ensureTotalCapacity(token_count);
    try index.frequencies.ensureTotalCapacity(token_count);
    for (0..token_count) |_| {
        if (offset + 6 > payload.len) return error.InvalidCorpusIndex;
        const len = std.mem.readInt(u16, payload[offset..][0..2], .little);
        const frequency = std.mem.readInt(u32, payload[offset + 2 ..][0..4], .little);
        offset += 6;
        if (len == 0 or offset + len > payload.len) return error.InvalidCorpusIndex;
        const token = try index.allocator.dupe(u8, payload[offset..][0..len]);
        offset += len;
        const id: u32 = @intCast(index.tokens.items.len);
        try index.tokens.append(token);
        try index.frequencies.append(frequency);
        try index.token_ids.put(token, id);
    }
    if (offset + 4 > payload.len) return error.InvalidCorpusIndex;
    const context_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
    offset += 4;
    if (context_count > MAX_CONTEXTS) return error.InvalidCorpusIndex;
    for (0..context_count) |_| {
        if (offset >= payload.len) return error.InvalidCorpusIndex;
        var key = ContextKey{ .len = payload[offset] };
        offset += 1;
        if (key.len < MIN_CONTEXT_WORDS or key.len > MAX_CONTEXT_WORDS or offset + key.len * 4 + 1 > payload.len) return error.InvalidCorpusIndex;
        for (0..key.len) |i| {
            key.ids[i] = std.mem.readInt(u32, payload[offset..][0..4], .little);
            offset += 4;
            if (key.ids[i] >= token_count) return error.InvalidCorpusIndex;
        }
        var bucket = Bucket{ .count = payload[offset] };
        offset += 1;
        if (bucket.count == 0 or bucket.count > MAX_CONTINUATIONS or offset + bucket.count * 8 > payload.len) return error.InvalidCorpusIndex;
        for (0..bucket.count) |i| {
            bucket.items[i] = .{ .token_id = std.mem.readInt(u32, payload[offset..][0..4], .little), .count = std.mem.readInt(u32, payload[offset + 4 ..][0..4], .little) };
            offset += 8;
            if (bucket.items[i].token_id >= token_count) return error.InvalidCorpusIndex;
        }
        try index.contexts.put(key, bucket);
    }
    if (offset != payload.len) return error.InvalidCorpusIndex;
    try index.finish();
}

fn findRecord(service: *Service, id: u32) ?*Record {
    for (service.records.items) |*record| if (record.metadata.id == id) return record;
    return null;
}
fn setMetadataText(metadata: *Metadata, source: []const u8) void {
    metadata.source_len = @intCast(source.len);
    @memcpy(metadata.source[0..source.len], source);
    const base = std.fs.path.basename(source);
    const name = base[0..@min(base.len, MAX_NAME_BYTES)];
    metadata.name_len = @intCast(name.len);
    @memcpy(metadata.name[0..name.len], name);
}
fn supportedPath(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".txt") or std.ascii.eqlIgnoreCase(extension, ".md");
}
fn isWordChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or (c == '\'');
}
fn addContinuation(bucket: *Bucket, token_id: u32) void {
    for (bucket.items[0..bucket.count]) |*item| if (item.token_id == token_id) {
        item.count +|= 1;
        return;
    };
    if (bucket.count < MAX_CONTINUATIONS) {
        bucket.items[bucket.count] = .{ .token_id = token_id, .count = 1 };
        bucket.count += 1;
        return;
    }
    var weakest: usize = 0;
    for (1..bucket.count) |i| {
        if (bucket.items[i].count < bucket.items[weakest].count) weakest = i;
    }
    if (bucket.items[weakest].count <= 1) bucket.items[weakest] = .{ .token_id = token_id, .count = 1 };
}
fn bestContinuation(bucket: Bucket) ?Continuation {
    if (bucket.count == 0) return null;
    var best = bucket.items[0];
    for (bucket.items[1..bucket.count]) |item| {
        if (item.count > best.count) best = item;
    }
    return best;
}
fn isAmbiguous(bucket: Bucket, best: Continuation) bool {
    for (bucket.items[0..bucket.count]) |item| if (item.token_id != best.token_id and item.count * 100 >= best.count * 80) return true;
    return false;
}
fn lessToken(index: *const Index, left: u32, right: u32) bool {
    return std.mem.order(u8, index.tokens.items[left], index.tokens.items[right]) == .lt;
}
fn appendWord(prediction: *Prediction, word: []const u8) bool {
    const extra = word.len + @intFromBool(prediction.len > 0);
    if (prediction.len + extra > prediction.text.len) return false;
    if (prediction.len > 0) {
        prediction.text[prediction.len] = ' ';
        prediction.len += 1;
    }
    @memcpy(prediction.text[prediction.len..][0..word.len], word);
    prediction.len += @intCast(word.len);
    return true;
}
fn insertPrediction(set: *PredictionSet, prediction: Prediction) void {
    var position: usize = 0;
    while (position < set.count and set.items[position].score >= prediction.score) position += 1;
    if (position >= set.items.len) return;
    const old_count: usize = set.count;
    if (old_count < set.items.len) set.count += 1;
    var index: usize = @min(old_count, set.items.len - 1);
    while (index > position) : (index -= 1) set.items[index] = set.items[index - 1];
    set.items[position] = prediction;
}
fn extractHistory(text: []const u8, words: *[MAX_CONTEXT_WORDS][64]u8, lens: *[MAX_CONTEXT_WORDS]u8) usize {
    var temporary: [MAX_CONTEXT_WORDS][64]u8 = undefined;
    var temp_lens: [MAX_CONTEXT_WORDS]u8 = [_]u8{0} ** MAX_CONTEXT_WORDS;
    var count: usize = 0;
    var current: [64]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (isWordChar(c)) {
            if (len < current.len) {
                current[len] = std.ascii.toLower(c);
                len += 1;
            }
        } else if (len > 0) {
            if (count < MAX_CONTEXT_WORDS) count += 1 else {
                std.mem.copyForwards([64]u8, temporary[0 .. MAX_CONTEXT_WORDS - 1], temporary[1..]);
                std.mem.copyForwards(u8, temp_lens[0 .. MAX_CONTEXT_WORDS - 1], temp_lens[1..]);
            }
            const slot = count - 1;
            @memcpy(temporary[slot][0..len], current[0..len]);
            temp_lens[slot] = @intCast(len);
            len = 0;
            if (c == '.' or c == '!' or c == '?' or c == '\n') count = 0;
        }
    }
    for (0..count) |i| {
        words[i] = temporary[i];
        lens[i] = temp_lens[i];
    }
    return count;
}

extern "user32" fn PostMessageA(hWnd: *anyopaque, Msg: u32, wParam: usize, lParam: isize) callconv(.C) i32;
const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
extern "kernel32" fn MoveFileExA(existing: [*:0]const u8, replacement: [*:0]const u8, flags: u32) callconv(.C) i32;
fn postMessage(window: *anyopaque, message: u32) i32 {
    return PostMessageA(window, message, 0, 0);
}
