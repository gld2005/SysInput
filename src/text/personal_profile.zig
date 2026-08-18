const std = @import("std");
const sysinput = @import("root").sysinput;

const autocomplete = sysinput.text.autocomplete;
const config = sysinput.core.config;

const MAGIC = "SYSIPRF1";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 8 + 2 + 4 + 4 + 4;
const MAX_FILE_SIZE: usize = 4 * 1024 * 1024;

pub const ProfileStore = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    path: []u8,
    temporary_path: []u8,

    pub fn initDefault(allocator: std.mem.Allocator) !ProfileStore {
        const executable_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(executable_dir);
        const directory = try std.fs.path.join(allocator, &.{ executable_dir, "data" });
        errdefer allocator.free(directory);
        const path = try std.fs.path.join(allocator, &.{ directory, "profile.bin" });
        errdefer allocator.free(path);
        const temporary_path = try std.fs.path.join(allocator, &.{ directory, "profile.bin.tmp" });
        return .{ .allocator = allocator, .directory = directory, .path = path, .temporary_path = temporary_path };
    }

    pub fn deinit(self: *ProfileStore) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.path);
        self.allocator.free(self.temporary_path);
    }

    pub fn load(self: *const ProfileStore, engine: *autocomplete.AutocompleteEngine) !void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, MAX_FILE_SIZE) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(bytes);
        try decodeInto(engine, bytes);
    }

    pub fn save(self: *const ProfileStore, engine: *const autocomplete.AutocompleteEngine) !void {
        try std.fs.cwd().makePath(self.directory);
        const bytes = try encode(self.allocator, engine);
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

pub fn encode(allocator: std.mem.Allocator, engine: *const autocomplete.AutocompleteEngine) ![]u8 {
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();
    for (0..engine.recordCount()) |index| {
        const record = engine.recordAt(index);
        if (record.word.len > std.math.maxInt(u16)) return error.WordTooLong;
        try appendInt(&payload, u16, @intCast(record.word.len));
        try payload.appendSlice(record.word);
        try appendInt(&payload, u32, record.stats.typed_count);
        try appendInt(&payload, u32, record.stats.shown_count);
        try appendInt(&payload, u32, record.stats.accepted_count);
        try appendInt(&payload, u64, record.stats.last_used);
        try appendInt(&payload, u64, record.stats.last_accepted);
        try appendInt(&payload, u16, record.stats.consecutive_ignores);
    }

    var output = try std.ArrayList(u8).initCapacity(allocator, HEADER_SIZE + payload.items.len);
    errdefer output.deinit();
    try output.appendSlice(MAGIC);
    try appendInt(&output, u16, VERSION);
    try appendInt(&output, u32, @intCast(engine.recordCount()));
    try appendInt(&output, u32, @intCast(payload.items.len));
    try appendInt(&output, u32, std.hash.Crc32.hash(payload.items));
    try output.appendSlice(payload.items);
    return output.toOwnedSlice();
}

pub fn decodeInto(engine: *autocomplete.AutocompleteEngine, bytes: []const u8) !void {
    if (bytes.len < HEADER_SIZE or bytes.len > MAX_FILE_SIZE) return error.InvalidProfile;
    if (!std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return error.InvalidProfile;
    var offset: usize = MAGIC.len;
    const version = try readInt(u16, bytes, &offset);
    if (version != VERSION) return error.UnsupportedProfileVersion;
    const count = try readInt(u32, bytes, &offset);
    if (count > config.BEHAVIOR.MAX_USER_WORDS) return error.InvalidProfile;
    const payload_len = try readInt(u32, bytes, &offset);
    const checksum = try readInt(u32, bytes, &offset);
    if (payload_len != bytes.len - HEADER_SIZE) return error.InvalidProfile;
    const payload = bytes[HEADER_SIZE..];
    if (std.hash.Crc32.hash(payload) != checksum) return error.InvalidProfile;

    const TemporaryRecord = struct { word: []const u8, stats: autocomplete.PersonalStats };
    var records = std.ArrayList(TemporaryRecord).init(engine.allocator);
    defer records.deinit();
    offset = HEADER_SIZE;
    for (0..count) |_| {
        const length = try readInt(u16, bytes, &offset);
        if (length < config.BEHAVIOR.MIN_TRIGGER_LEN or length > config.TEXT.MAX_SUGGESTION_LEN or
            offset + length > bytes.len) return error.InvalidProfile;
        const word = bytes[offset .. offset + length];
        offset += length;
        const stats = autocomplete.PersonalStats{
            .typed_count = try readInt(u32, bytes, &offset),
            .shown_count = try readInt(u32, bytes, &offset),
            .accepted_count = try readInt(u32, bytes, &offset),
            .last_used = try readInt(u64, bytes, &offset),
            .last_accepted = try readInt(u64, bytes, &offset),
            .consecutive_ignores = try readInt(u16, bytes, &offset),
        };
        try records.append(.{ .word = word, .stats = stats });
    }
    if (offset != bytes.len) return error.InvalidProfile;
    for (records.items) |record| try engine.restoreRecord(record.word, record.stats);
}

fn appendInt(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(&bytes);
}

fn readInt(comptime T: type, bytes: []const u8, offset: *usize) !T {
    if (offset.* + @sizeOf(T) > bytes.len) return error.InvalidProfile;
    const value = std.mem.readInt(T, bytes[offset.*..][0..@sizeOf(T)], .little);
    offset.* += @sizeOf(T);
    return value;
}
