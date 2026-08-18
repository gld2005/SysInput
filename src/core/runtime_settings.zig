const std = @import("std");

const MAGIC = "SYSISET1";
const VERSION: u16 = 3;
const HEADER_SIZE: usize = 8 + 2 + 2 + 4;
const PAYLOAD_SIZE: usize = 6;
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
    abbreviation_auto_expand,
};

pub const Theme = enum(u8) { system, light, dark };
pub const Accent = enum(u8) { system, blue, teal, purple };
pub const Density = enum(u8) { compact, comfortable };

pub const Appearance = struct {
    theme: Theme = .system,
    accent: Accent = .system,
    density: Density = .compact,
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
    abbreviation_auto_expand: bool,
    abbreviation_prefix: u8,
    appearance: Appearance,
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
    abbreviation_prefix: std.atomic.Value(u8),
    theme: std.atomic.Value(u8),
    accent: std.atomic.Value(u8),
    density: std.atomic.Value(u8),
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
            const decoded = decodeData(contents) catch {
                flags = DEFAULT_FLAGS;
                status = .corrupt;
                return .{ .store = .{
                    .allocator = allocator,
                    .path = path,
                    .temporary_path = temporary_path,
                    .flags = std.atomic.Value(u16).init(flags),
                    .abbreviation_prefix = std.atomic.Value(u8).init(';'),
                    .theme = std.atomic.Value(u8).init(@intFromEnum(Theme.system)),
                    .accent = std.atomic.Value(u8).init(@intFromEnum(Accent.system)),
                    .density = std.atomic.Value(u8).init(@intFromEnum(Density.compact)),
                }, .status = status };
            };
            flags = decoded.flags;
            status = .loaded;
            return .{ .store = .{
                .allocator = allocator,
                .path = path,
                .temporary_path = temporary_path,
                .flags = std.atomic.Value(u16).init(flags),
                .abbreviation_prefix = std.atomic.Value(u8).init(decoded.prefix),
                .theme = std.atomic.Value(u8).init(@intFromEnum(decoded.appearance.theme)),
                .accent = std.atomic.Value(u8).init(@intFromEnum(decoded.appearance.accent)),
                .density = std.atomic.Value(u8).init(@intFromEnum(decoded.appearance.density)),
            }, .status = status };
        }
        return .{ .store = .{
            .allocator = allocator,
            .path = path,
            .temporary_path = temporary_path,
            .flags = std.atomic.Value(u16).init(flags),
            .abbreviation_prefix = std.atomic.Value(u8).init(';'),
            .theme = std.atomic.Value(u8).init(@intFromEnum(Theme.system)),
            .accent = std.atomic.Value(u8).init(@intFromEnum(Accent.system)),
            .density = std.atomic.Value(u8).init(@intFromEnum(Density.compact)),
        }, .status = status };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.allocator.free(self.temporary_path);
    }

    pub fn snapshot(self: *const Store) Snapshot {
        var result = snapshotFromFlags(self.flags.load(.acquire));
        result.abbreviation_prefix = self.abbreviation_prefix.load(.acquire);
        result.appearance = self.appearance();
        return result;
    }

    pub fn appearance(self: *const Store) Appearance {
        return .{
            .theme = @enumFromInt(self.theme.load(.acquire)),
            .accent = @enumFromInt(self.accent.load(.acquire)),
            .density = @enumFromInt(self.density.load(.acquire)),
        };
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

    pub fn setAbbreviationPrefixAndSave(self: *Store, prefix: u8) !void {
        if (std.ascii.isAlphanumeric(prefix) or std.ascii.isWhitespace(prefix)) return error.InvalidAbbreviationPrefix;
        self.abbreviation_prefix.store(prefix, .release);
        try self.save();
    }

    pub fn setAppearanceAndSave(self: *Store, value: Appearance) !void {
        self.theme.store(@intFromEnum(value.theme), .release);
        self.accent.store(@intFromEnum(value.accent), .release);
        self.density.store(@intFromEnum(value.density), .release);
        try self.save();
    }

    pub fn save(self: *Store) !void {
        self.save_mutex.lock();
        defer self.save_mutex.unlock();
        const bytes = encodeWithValues(
            self.flags.load(.acquire),
            self.abbreviation_prefix.load(.acquire),
            self.appearance(),
        );
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
        .abbreviation_auto_expand = flags & mask(.abbreviation_auto_expand) != 0,
        .abbreviation_prefix = ';',
        .appearance = .{},
    };
}

pub fn encode(flags: u16) [HEADER_SIZE + PAYLOAD_SIZE]u8 {
    return encodeWithValues(flags, ';', .{});
}

fn encodeWithValues(flags: u16, prefix: u8, appearance: Appearance) [HEADER_SIZE + PAYLOAD_SIZE]u8 {
    var result: [HEADER_SIZE + PAYLOAD_SIZE]u8 = undefined;
    @memcpy(result[0..MAGIC.len], MAGIC);
    std.mem.writeInt(u16, result[8..10], VERSION, .little);
    std.mem.writeInt(u16, result[10..12], PAYLOAD_SIZE, .little);
    std.mem.writeInt(u16, result[HEADER_SIZE..][0..2], flags, .little);
    result[HEADER_SIZE + 2] = prefix;
    result[HEADER_SIZE + 3] = @intFromEnum(appearance.theme);
    result[HEADER_SIZE + 4] = @intFromEnum(appearance.accent);
    result[HEADER_SIZE + 5] = @intFromEnum(appearance.density);
    const checksum = std.hash.Crc32.hash(result[HEADER_SIZE..]);
    std.mem.writeInt(u32, result[12..16], checksum, .little);
    return result;
}

pub fn decode(bytes: []const u8) !u16 {
    return (try decodeData(bytes)).flags;
}

const Decoded = struct { flags: u16, prefix: u8, appearance: Appearance };
fn decodeData(bytes: []const u8) !Decoded {
    if (bytes.len < HEADER_SIZE + 2 or bytes.len > MAX_FILE_SIZE) return error.InvalidSettings;
    if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return error.InvalidSettings;
    const version = std.mem.readInt(u16, bytes[8..10], .little);
    const payload_size = std.mem.readInt(u16, bytes[10..12], .little);
    if (!((version == 1 and payload_size == 2) or
        (version == 2 and payload_size == 3) or
        (version == VERSION and payload_size == PAYLOAD_SIZE))) return error.UnsupportedSettingsVersion;
    if (bytes.len != HEADER_SIZE + payload_size) return error.InvalidSettings;
    if (std.hash.Crc32.hash(bytes[HEADER_SIZE..]) != std.mem.readInt(u32, bytes[12..16], .little)) return error.InvalidSettings;
    const flags = std.mem.readInt(u16, bytes[HEADER_SIZE..][0..2], .little);
    const known_bits = (@as(u16, 1) << (@intFromEnum(Feature.abbreviation_auto_expand) + 1)) - 1;
    if (flags & ~known_bits != 0) return error.InvalidSettings;
    const prefix = if (version == 1) @as(u8, ';') else bytes[HEADER_SIZE + 2];
    if (std.ascii.isAlphanumeric(prefix) or std.ascii.isWhitespace(prefix)) return error.InvalidSettings;
    const appearance: Appearance = if (version < 3) .{} else .{
        .theme = std.meta.intToEnum(Theme, bytes[HEADER_SIZE + 3]) catch return error.InvalidSettings,
        .accent = std.meta.intToEnum(Accent, bytes[HEADER_SIZE + 4]) catch return error.InvalidSettings,
        .density = std.meta.intToEnum(Density, bytes[HEADER_SIZE + 5]) catch return error.InvalidSettings,
    };
    return .{ .flags = flags, .prefix = prefix, .appearance = appearance };
}
