const std = @import("std");

pub const MAX_CHUNKS: usize = 12;
pub const MAX_CONFIDENCE: u16 = 1000;

pub const CandidateKind = enum(u8) {
    word_completion,
    next_word,
    phrase_completion,
    sentence_completion,
};

pub const CandidateSource = enum(u8) {
    dictionary,
    personal_frequency,
    spelling,
    learned_phrase,
    repeated_sentence,
};

pub const ChunkKind = enum(u8) {
    word,
    phrase,
    punctuation,
};

pub const Chunk = struct {
    start: u16,
    len: u16,
    kind: ChunkKind,

    pub fn end(self: Chunk) usize {
        return @as(usize, self.start) + @as(usize, self.len);
    }
};

pub const CandidateError = error{
    TextTooLong,
    ReplaceRangeTooLong,
    InvalidChunkRange,
    TooManyChunks,
};

/// A scored prediction candidate. Text slices are borrowed from the result
/// owner; the Candidate itself performs no allocation.
pub const Candidate = struct {
    kind: CandidateKind,
    source: CandidateSource,
    display_text: []const u8,
    insert_text: []const u8,
    replace_length: u16,
    score: i32,
    confidence: u16,
    chunks: [MAX_CHUNKS]Chunk,
    chunk_count: u8,
    active_chunk: u8,

    pub fn init(
        kind: CandidateKind,
        source: CandidateSource,
        display_text: []const u8,
        insert_text: []const u8,
        replace_length: usize,
        score: i32,
        confidence: u16,
    ) CandidateError!Candidate {
        if (display_text.len > std.math.maxInt(u16) or insert_text.len > std.math.maxInt(u16)) {
            return error.TextTooLong;
        }
        if (replace_length > std.math.maxInt(u16)) return error.ReplaceRangeTooLong;

        return .{
            .kind = kind,
            .source = source,
            .display_text = display_text,
            .insert_text = insert_text,
            .replace_length = @intCast(replace_length),
            .score = score,
            .confidence = @min(confidence, MAX_CONFIDENCE),
            .chunks = undefined,
            .chunk_count = 0,
            .active_chunk = 0,
        };
    }

    pub fn wordCompletion(
        text: []const u8,
        replace_length: usize,
        source: CandidateSource,
        score: i32,
        confidence: u16,
    ) CandidateError!Candidate {
        var result = try init(
            .word_completion,
            source,
            text,
            text,
            replace_length,
            score,
            confidence,
        );
        if (text.len > 0) try result.addChunk(0, text.len, .word);
        return result;
    }

    pub fn addChunk(self: *Candidate, start: usize, len: usize, kind: ChunkKind) CandidateError!void {
        if (self.chunk_count >= MAX_CHUNKS) return error.TooManyChunks;
        if (len == 0 or start > self.insert_text.len or len > self.insert_text.len - start) {
            return error.InvalidChunkRange;
        }
        const expected_start = if (self.chunk_count == 0)
            0
        else
            self.chunks[self.chunk_count - 1].end();
        if (start != expected_start) return error.InvalidChunkRange;
        if (start > std.math.maxInt(u16) or len > std.math.maxInt(u16)) {
            return error.InvalidChunkRange;
        }

        self.chunks[self.chunk_count] = .{
            .start = @intCast(start),
            .len = @intCast(len),
            .kind = kind,
        };
        self.chunk_count += 1;
    }

    pub fn currentChunk(self: *const Candidate) ?Chunk {
        if (self.active_chunk >= self.chunk_count) return null;
        return self.chunks[self.active_chunk];
    }

    pub fn currentChunkText(self: *const Candidate) []const u8 {
        const chunk = self.currentChunk() orelse return "";
        return self.insert_text[chunk.start..chunk.end()];
    }

    pub fn remainingText(self: *const Candidate) []const u8 {
        const chunk = self.currentChunk() orelse return "";
        return self.insert_text[chunk.start..];
    }

    pub fn advanceChunk(self: *Candidate) bool {
        if (self.active_chunk >= self.chunk_count) return false;
        self.active_chunk += 1;
        return self.active_chunk < self.chunk_count;
    }

    pub fn isValid(self: *const Candidate) bool {
        if (self.confidence > MAX_CONFIDENCE or self.active_chunk > self.chunk_count) return false;
        var expected_start: usize = 0;
        for (self.chunks[0..self.chunk_count]) |chunk| {
            if (chunk.len == 0 or chunk.start != expected_start or chunk.end() > self.insert_text.len) return false;
            expected_start = chunk.end();
        }
        return self.chunk_count == 0 or expected_start == self.insert_text.len;
    }
};
