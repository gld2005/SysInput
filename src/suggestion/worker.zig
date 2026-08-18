const std = @import("std");
const sysinput = @import("root").sysinput;

const api = sysinput.win32.api;
const config = sysinput.core.config;
const candidate_model = sysinput.suggestion.candidate;

pub const WM_PREDICTION_READY = api.WM_APP + 1;
pub const MAX_LEARNING_QUEUE: usize = 16;

pub const PredictionRequest = struct {
    version: u64 = 0,
    target_window: ?api.HWND = null,
    text: [config.TEXT.MAX_BUFFER_SIZE]u8 = undefined,
    text_len: u16 = 0,
    word: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    word_len: u16 = 0,

    pub fn set(self: *PredictionRequest, version: u64, text: []const u8, word: []const u8) void {
        self.version = version;
        self.target_window = api.GetForegroundWindow();
        const text_len = @min(text.len, self.text.len);
        const word_len = @min(word.len, self.word.len);
        @memcpy(self.text[0..text_len], text[0..text_len]);
        @memcpy(self.word[0..word_len], word[0..word_len]);
        self.text_len = @intCast(text_len);
        self.word_len = @intCast(word_len);
    }

    pub fn textSlice(self: *const PredictionRequest) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn wordSlice(self: *const PredictionRequest) []const u8 {
        return self.word[0..self.word_len];
    }
};

pub const ResultCandidate = struct {
    kind: candidate_model.CandidateKind = .word_completion,
    source: candidate_model.CandidateSource = .dictionary,
    display_text: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    display_len: u16 = 0,
    insert_text: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    insert_len: u16 = 0,
    replace_length: u16 = 0,
    score: i32 = 0,
    confidence: u16 = 0,
    chunks: [candidate_model.MAX_CHUNKS]candidate_model.Chunk = undefined,
    chunk_count: u8 = 0,
    active_chunk: u8 = 0,

    pub fn set(self: *ResultCandidate, source: *const candidate_model.Candidate) bool {
        if (source.display_text.len > self.display_text.len or source.insert_text.len > self.insert_text.len) {
            return false;
        }
        @memcpy(self.display_text[0..source.display_text.len], source.display_text);
        @memcpy(self.insert_text[0..source.insert_text.len], source.insert_text);
        self.display_len = @intCast(source.display_text.len);
        self.insert_len = @intCast(source.insert_text.len);
        self.kind = source.kind;
        self.source = source.source;
        self.replace_length = source.replace_length;
        self.score = source.score;
        self.confidence = source.confidence;
        self.chunk_count = source.chunk_count;
        self.active_chunk = source.active_chunk;
        @memcpy(self.chunks[0..source.chunk_count], source.chunks[0..source.chunk_count]);
        return true;
    }

    pub fn displaySlice(self: *const ResultCandidate) []const u8 {
        return self.display_text[0..self.display_len];
    }

    pub fn insertSlice(self: *const ResultCandidate) []const u8 {
        return self.insert_text[0..self.insert_len];
    }
};

pub const PredictionResult = struct {
    version: u64 = 0,
    target_window: ?api.HWND = null,
    text: [config.TEXT.MAX_BUFFER_SIZE]u8 = undefined,
    text_len: u16 = 0,
    word: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    word_len: u16 = 0,
    candidates: [config.TEXT.MAX_SUGGESTIONS]ResultCandidate = undefined,
    candidate_count: u8 = 0,

    pub fn resetFromRequest(self: *PredictionResult, request: *const PredictionRequest) void {
        self.version = request.version;
        self.target_window = request.target_window;
        self.text_len = request.text_len;
        self.word_len = request.word_len;
        @memcpy(self.text[0..request.text_len], request.textSlice());
        @memcpy(self.word[0..request.word_len], request.wordSlice());
        self.candidate_count = 0;
    }

    pub fn addCandidate(self: *PredictionResult, candidate: *const candidate_model.Candidate) bool {
        if (self.candidate_count >= self.candidates.len) return false;
        if (!self.candidates[self.candidate_count].set(candidate)) return false;
        self.candidate_count += 1;
        return true;
    }

    pub fn textSlice(self: *const PredictionResult) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn wordSlice(self: *const PredictionResult) []const u8 {
        return self.word[0..self.word_len];
    }
};

const LearningItem = struct {
    text: [config.TEXT.MAX_SUGGESTION_LEN]u8 = undefined,
    len: u16 = 0,

    fn set(self: *LearningItem, text: []const u8) void {
        const len = @min(text.len, self.text.len);
        @memcpy(self.text[0..len], text[0..len]);
        self.len = @intCast(len);
    }

    fn slice(self: *const LearningItem) []const u8 {
        return self.text[0..self.len];
    }
};

pub const ComputeCallback = *const fn (*const PredictionRequest, *PredictionResult) anyerror!void;
pub const DeliverCallback = *const fn (*const PredictionResult) void;
pub const LearnCallback = *const fn ([]const u8) anyerror!void;

var mutex = std.Thread.Mutex{};
var condition = std.Thread.Condition{};
var worker_thread: ?std.Thread = null;
var stopping = false;
var pending_request: PredictionRequest = .{};
var request_pending = false;
var latest_submitted_version: u64 = 0;
var ready_result: PredictionResult = .{};
var result_ready = false;
var learning_queue: [MAX_LEARNING_QUEUE]LearningItem = undefined;
var learning_head: usize = 0;
var learning_count: usize = 0;
var ui_thread_id: api.DWORD = 0;
var compute_callback: ComputeCallback = undefined;
var deliver_callback: DeliverCallback = undefined;
var learn_callback: LearnCallback = undefined;

pub fn init(compute: ComputeCallback, deliver: DeliverCallback, learn: LearnCallback) !void {
    if (worker_thread != null) return;
    compute_callback = compute;
    deliver_callback = deliver;
    learn_callback = learn;
    ui_thread_id = api.GetCurrentThreadId();
    stopping = false;
    request_pending = false;
    result_ready = false;
    latest_submitted_version = 0;
    learning_head = 0;
    learning_count = 0;
    worker_thread = try std.Thread.spawn(.{}, workerMain, .{});
}

pub fn deinit() void {
    mutex.lock();
    stopping = true;
    condition.signal();
    mutex.unlock();

    if (worker_thread) |thread| thread.join();
    worker_thread = null;
}

pub fn submitPrediction(text: []const u8, word: []const u8) u64 {
    mutex.lock();
    defer mutex.unlock();

    latest_submitted_version +%= 1;
    if (latest_submitted_version == 0) latest_submitted_version = 1;
    pending_request.set(latest_submitted_version, text, word);
    request_pending = true;
    result_ready = false;
    condition.signal();
    return latest_submitted_version;
}

pub fn submitLearnedWord(word: []const u8) void {
    if (word.len == 0) return;
    mutex.lock();
    defer mutex.unlock();

    if (learning_count == learning_queue.len) {
        learning_head = (learning_head + 1) % learning_queue.len;
        learning_count -= 1;
    }
    const tail = (learning_head + learning_count) % learning_queue.len;
    learning_queue[tail].set(word);
    learning_count += 1;
    condition.signal();
}

pub fn dispatchReady() void {
    var result: PredictionResult = undefined;

    mutex.lock();
    if (!result_ready or ready_result.version != latest_submitted_version) {
        result_ready = false;
        mutex.unlock();
        return;
    }
    result = ready_result;
    result_ready = false;
    mutex.unlock();

    deliver_callback(&result);
}

pub fn latestVersion() u64 {
    mutex.lock();
    defer mutex.unlock();
    return latest_submitted_version;
}

fn popLearningLocked() ?LearningItem {
    if (learning_count == 0) return null;
    const item = learning_queue[learning_head];
    learning_head = (learning_head + 1) % learning_queue.len;
    learning_count -= 1;
    return item;
}

fn workerMain() void {
    while (true) {
        var request: ?PredictionRequest = null;
        var learning: ?LearningItem = null;

        mutex.lock();
        while (!stopping and !request_pending and learning_count == 0) {
            condition.wait(&mutex);
        }
        if (stopping) {
            mutex.unlock();
            return;
        }
        learning = popLearningLocked();
        if (request_pending) {
            request = pending_request;
            request_pending = false;
        }
        mutex.unlock();

        if (learning) |item| {
            learn_callback(item.slice()) catch |err| {
                std.debug.print("Prediction learning task failed: {}\n", .{err});
            };
        }

        if (request) |current_request| {
            var result: PredictionResult = undefined;
            result.resetFromRequest(&current_request);
            compute_callback(&current_request, &result) catch |err| {
                std.debug.print("Prediction task failed: {}\n", .{err});
                result.candidate_count = 0;
            };

            mutex.lock();
            if (!stopping and current_request.version == latest_submitted_version) {
                ready_result = result;
                result_ready = true;
                mutex.unlock();
                _ = api.PostThreadMessageA(ui_thread_id, WM_PREDICTION_READY, 0, 0);
            } else {
                mutex.unlock();
            }
        }
    }
}
