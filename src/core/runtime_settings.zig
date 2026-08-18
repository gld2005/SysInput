const std = @import("std");

const MAGIC = "SYSISET1";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 8 + 2 + 2 + 4;
const PAYLOAD_SIZE: usize = 2;
const MAX_FILE_SIZE: usize = 1024;

pub const Feature = enum(u4) {
    enabled,
    start_with_windows,
    word_completion,
    next_word_prediction,
    phrase_completion,
    sentence_prediction,
    personal_learning,
    abbreviation_expansion,
    corpus_prediction,
    safe_arrow_mode,
};

pub const Snapshot = struct {
    enabled: bool,
    start_with_windows: bool,
    word_completion: bool,
    next_word_prediction: bool,
    phrase_completion: bool,
    sentence_prediction: bool,
    personal_learning: bool,
    abbreviation_expansion: bool,
    corpus_prediction: bool,
    safe_arrow_mode: bool,
};

pub const LoadStatus = enum { loaded, missing, corrupt };

const DEFAULT_FLAGS: u16 = mask(.enabled) |
    mask(.start_with_windows) |
    mask(.word_completion) |
    mask(.next_word_prediction) |
    mask(.phrase_completion) |
    mask(.sentence_prediction) |
    mask(.personal_learning) |
    mask(.safe_arrow_mode);

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    temporary_path: []u8,
    flags: std.atomic.Value(u16),
    save_mutex: std.Thread.Mutex = .{},

    pub fn initAt(allocator: std.mem.Allocator, directory: []const u8) !struct { store: Store, status: LoadStatus } {
        try std.fs.cwd().makePath(directory);
        const path = try std.fs.path.join(allocator, &.{ directory, "settings.bin" });
        errdefer allocator.free(path);
        const temporary_path = try std.fs.path.join(allocator, &.{ directory, "settings.bin.tmp" });
        errdefer allocator.free(temporary_path);

        var flags = DEFAULT_FLAGS;
        var status: LoadStatus = .missing;
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_FILE_SIZE) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (bytes) |contents| {
            defer allocator.free(contents);
            flags = decode(contents) catch {
                flags = DEFAULT_FLAGS;
                status = .corrupt;
                return .{ .store = .{
                    .allocator = allocator,
                    .path = path,
                    .temporary_path = temporary_path,
                    .flags = std.atomic.Value(u16).init(flags),
                }, .status = status };
            };
            status = .loaded;
        }
        return .{ .store = .{
            .allocator = allocator,
            .path = path,
            .temporary_path = temporary_path,
            .flags = std.atomic.Value(u16).init(flags),
        }, .status = status };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.allocator.free(self.temporary_path);
    }

    pub fn snapshot(self: *const Store) Snapshot {
        return snapshotFromFlags(self.flags.load(.acquire));
    }

    pub fn isEnabled(self: *const Store, feature: Feature) bool {
        return self.flags.load(.acquire) & mask(feature) != 0;
    }

    pub fn set(self: *Store, feature: Feature, enabled: bool) void {
        const bit = mask(feature);
        if (enabled) {
            _ = self.flags.fetchOr(bit, .acq_rel);
        } else {
            _ = self.flags.fetchAnd(~bit, .acq_rel);
        }
    }

    pub fn setAndSave(self: *Store, feature: Feature, enabled: bool) !void {
        self.set(feature, enabled);
        try self.save();
    }

    pub fn save(self: *Store) !void {
        self.save_mutex.lock();
        defer self.save_mutex.unlock();
        const bytes = encode(self.flags.load(.acquire));
        var file = try std.fs.cwd().createFile(self.temporary_path, .{ .truncate = true });
        var open = true;
        defer if (open) file.close();
        errdefer std.fs.cwd().deleteFile(self.temporary_path) catch {};
        try file.writeAll(&bytes);
        try file.sync();
        file.close();
        open = false;
        try std.fs.renameAbsolute(self.temporary_path, self.path);
    }
};

pub fn defaultSnapshot() Snapshot {
    return snapshotFromFlags(DEFAULT_FLAGS);
}

pub fn mask(feature: Feature) u16 {
    return @as(u16, 1) << @intFromEnum(feature);
}

pub fn snapshotFromFlags(flags: u16) Snapshot {
    return .{
        .enabled = flags & mask(.enabled) != 0,
        .start_with_windows = flags & mask(.start_with_windows) != 0,
        .word_completion = flags & mask(.word_completion) != 0,
        .next_word_prediction = flags & mask(.next_word_prediction) != 0,
        .phrase_completion = flags & mask(.phrase_completion) != 0,
        .sentence_prediction = flags & mask(.sentence_prediction) != 0,
        .personal_learning = flags & mask(.personal_learning) != 0,
        .abbreviation_expansion = flags & mask(.abbreviation_expansion) != 0,
        .corpus_prediction = flags & mask(.corpus_prediction) != 0,
        .safe_arrow_mode = flags & mask(.safe_arrow_mode) != 0,
    };
}

pub fn encode(flags: u16) [HEADER_SIZE + PAYLOAD_SIZE]u8 {
    var result: [HEADER_SIZE + PAYLOAD_SIZE]u8 = undefined;
    @memcpy(result[0..MAGIC.len], MAGIC);
    std.mem.writeInt(u16, result[8..10], VERSION, .little);
    std.mem.writeInt(u16, result[10..12], PAYLOAD_SIZE, .little);
    std.mem.writeInt(u16, result[HEADER_SIZE..][0..2], flags, .little);
    const checksum = std.hash.Crc32.hash(result[HEADER_SIZE..]);
    std.mem.writeInt(u32, result[12..16], checksum, .little);
    return result;
}

pub fn decode(bytes: []const u8) !u16 {
    if (bytes.len != HEADER_SIZE + PAYLOAD_SIZE or bytes.len > MAX_FILE_SIZE) return error.InvalidSettings;
    if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return error.InvalidSettings;
    if (std.mem.readInt(u16, bytes[8..10], .little) != VERSION) return error.UnsupportedSettingsVersion;
    if (std.mem.readInt(u16, bytes[10..12], .little) != PAYLOAD_SIZE) return error.InvalidSettings;
    if (std.hash.Crc32.hash(bytes[HEADER_SIZE..]) != std.mem.readInt(u32, bytes[12..16], .little)) return error.InvalidSettings;
    const flags = std.mem.readInt(u16, bytes[HEADER_SIZE..][0..2], .little);
    const known_bits = (@as(u16, 1) << (@intFromEnum(Feature.safe_arrow_mode) + 1)) - 1;
    if (flags & ~known_bits != 0) return error.InvalidSettings;
    return flags;
}
