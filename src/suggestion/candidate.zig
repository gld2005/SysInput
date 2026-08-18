const std = @import("std");

pub const MAX_CHUNKS: usize = 12;
pub const MAX_CONFIDENCE: u16 = 1000;

pub const AcceptanceMode = enum(u8) {
    chunk,
    word,
};

pub const Acceptance = struct {
    text: []const u8,
    consumed_len: usize,
};

pub const CandidateKind = enum(u8) {
    word_completion,
    next_word,
    phrase_completion,
    sentence_completion,
    abbreviation_expansion,
};

pub const CandidateSource = enum(u8) {
    dictionary,
    personal_frequency,
    spelling,
    learned_phrase,
    repeated_sentence,
    user_abbreviation,
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

    /// Selects the smallest text unit requested by the acceptance key. Word
    /// completion remains an all-or-nothing replacement; append candidates
    /// can be consumed one chunk or one whitespace-delimited word at a time.
    pub fn acceptance(self: *const Candidate, mode: AcceptanceMode) ?Acceptance {
        if (self.kind == .word_completion or (self.kind == .abbreviation_expansion and mode == .chunk)) {
            if (self.insert_text.len == 0) return null;
            return .{ .text = self.insert_text, .consumed_len = self.insert_text.len };
        }

        const remaining = self.remainingText();
        if (remaining.len == 0) return null;
        return switch (mode) {
            .chunk => blk: {
                const chunk = self.currentChunk() orelse break :blk null;
                const raw = self.insert_text[chunk.start..chunk.end()];
                const text = std.mem.trim(u8, raw, " \t\r\n");
                if (text.len == 0) break :blk null;
                break :blk .{ .text = text, .consumed_len = raw.len };
            },
            .word => blk: {
                const start = skipWhitespace(remaining, 0);
                if (start == remaining.len) break :blk null;
                var end = start;
                while (end < remaining.len and !std.ascii.isWhitespace(remaining[end])) : (end += 1) {}
                break :blk .{ .text = remaining[start..end], .consumed_len = end };
            },
        };
    }

    pub fn remainingAfter(self: *const Candidate, accepted: Acceptance) []const u8 {
        const remaining = self.remainingText();
        if (accepted.consumed_len >= remaining.len) return "";
        const start = skipWhitespace(remaining, accepted.consumed_len);
        return remaining[start..];
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

/// Rebuilds lightweight phrase chunks for an optimistic remainder. Chunks are
/// contiguous, contain at most four words, and close at comma/semicolon/colon.
pub fn buildCompletionChunks(text: []const u8, chunks: *[MAX_CHUNKS]Chunk) u8 {
    if (text.len == 0 or text.len > std.math.maxInt(u16)) return 0;

    var count: usize = 0;
    var chunk_start: usize = 0;
    var words: usize = 0;
    var in_word = false;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const character = text[index];
        if (std.ascii.isWhitespace(character)) {
            in_word = false;
            continue;
        }
        if (!in_word) {
            if (words == 4) {
                if (!appendBuiltChunk(text, chunks, &count, chunk_start, index, words)) return @intCast(count);
                chunk_start = index;
                words = 0;
            }
            words += 1;
            in_word = true;
        }
        if (character == ',' or character == ';' or character == ':') {
            if (!appendBuiltChunk(text, chunks, &count, chunk_start, index + 1, words)) return @intCast(count);
            chunk_start = index + 1;
            words = 0;
            in_word = false;
        }
    }
    if (chunk_start < text.len) {
        if (count == MAX_CHUNKS) {
            chunks[count - 1].len = @intCast(text.len - chunks[count - 1].start);
        } else {
            _ = appendBuiltChunk(text, chunks, &count, chunk_start, text.len, words);
        }
    }
    return @intCast(count);
}

fn skipWhitespace(text: []const u8, initial: usize) usize {
    var index = initial;
    while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
    return index;
}

fn appendBuiltChunk(
    text: []const u8,
    chunks: *[MAX_CHUNKS]Chunk,
    count: *usize,
    start: usize,
    end: usize,
    words: usize,
) bool {
    if (end <= start or words == 0) return true;
    if (count.* == MAX_CHUNKS) {
        chunks[count.* - 1].len = @intCast(text.len - chunks[count.* - 1].start);
        return false;
    }
    chunks[count.*] = .{
        .start = @intCast(start),
        .len = @intCast(end - start),
        .kind = if (words == 1) .word else .phrase,
    };
    count.* += 1;
    return true;
}
