const std = @import("std");

const MAGIC = "SYSIEXC1";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 8 + 2 + 2 + 4 + 4;
const MAX_FILE_SIZE: usize = 256 * 1024;
pub const MAX_ENTRIES: usize = 128;
pub const MAX_PATH_BYTES: usize = 1024;

pub const Entry = struct {
    path: [MAX_PATH_BYTES]u8 = undefined,
    path_len: u16 = 0,
    enabled: bool = true,

    pub fn pathSlice(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const LoadStatus = enum { loaded, missing, corrupt };

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    temporary_path: []u8,
    entries: [MAX_ENTRIES]Entry = undefined,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn initAt(allocator: std.mem.Allocator, directory: []const u8) !struct { store: Store, status: LoadStatus } {
        try std.fs.cwd().makePath(directory);
        const path = try std.fs.path.join(allocator, &.{ directory, "exclusions.bin" });
        errdefer allocator.free(path);
        const temporary_path = try std.fs.path.join(allocator, &.{ directory, "exclusions.bin.tmp" });
        errdefer allocator.free(temporary_path);
        var store = Store{ .allocator = allocator, .path = path, .temporary_path = temporary_path };

        const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_FILE_SIZE) catch |err| switch (err) {
            error.FileNotFound => return .{ .store = store, .status = .missing },
            else => return err,
        };
        defer allocator.free(bytes);
        decodeInto(&store, bytes) catch return .{ .store = store, .status = .corrupt };
        return .{ .store = store, .status = .loaded };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.allocator.free(self.temporary_path);
    }

    pub fn currentGeneration(self: *const Store) u64 {
        return self.generation.load(.acquire);
    }

    pub fn contains(self: *Store, raw_path: []const u8) bool {
        var normalized: [MAX_PATH_BYTES]u8 = undefined;
        const path = normalizePath(raw_path, &normalized) orelse return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.count]) |*entry| {
            if (entry.enabled and std.mem.eql(u8, entry.pathSlice(), path)) return true;
        }
        return false;
    }

    pub fn add(self: *Store, raw_path: []const u8) !bool {
        var normalized: [MAX_PATH_BYTES]u8 = undefined;
        const path = normalizePath(raw_path, &normalized) orelse return error.InvalidApplicationPath;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.count]) |*entry| {
            if (!std.mem.eql(u8, entry.pathSlice(), path)) continue;
            if (!entry.enabled) {
                entry.enabled = true;
                self.bumpGeneration();
                try self.saveLocked();
            }
            return false;
        }
        if (self.count >= MAX_ENTRIES) return error.ExclusionLimitReached;
        var entry = &self.entries[self.count];
        @memcpy(entry.path[0..path.len], path);
        entry.path_len = @intCast(path.len);
        entry.enabled = true;
        self.count += 1;
        self.bumpGeneration();
        try self.saveLocked();
        return true;
    }

    pub fn remove(self: *Store, index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.count) return error.InvalidExclusionIndex;
        var cursor = index;
        while (cursor + 1 < self.count) : (cursor += 1) self.entries[cursor] = self.entries[cursor + 1];
        self.count -= 1;
        self.bumpGeneration();
        try self.saveLocked();
    }

    pub fn setEnabled(self: *Store, index: usize, enabled: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.count) return error.InvalidExclusionIndex;
        if (self.entries[index].enabled == enabled) return;
        self.entries[index].enabled = enabled;
        self.bumpGeneration();
        try self.saveLocked();
    }

    pub fn copyEntries(self: *Store, output: []Entry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const length = @min(output.len, self.count);
        @memcpy(output[0..length], self.entries[0..length]);
        return length;
    }

    pub fn save(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.saveLocked();
    }

    fn bumpGeneration(self: *Store) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
    }

    fn saveLocked(self: *Store) !void {
        const bytes = try encode(self.allocator, self.entries[0..self.count]);
        defer self.allocator.free(bytes);
        var file = try std.fs.cwd().createFile(self.temporary_path, .{ .truncate = true });
        var open = true;
        defer if (open) file.close();
        errdefer std.fs.cwd().deleteFile(self.temporary_path) catch {};
        try file.writeAll(bytes);
        try file.sync();
        file.close();
        open = false;
        try std.fs.renameAbsolute(self.temporary_path, self.path);
    }
};

pub fn normalizePath(raw_path: []const u8, storage: *[MAX_PATH_BYTES]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n\"");
    if (trimmed.len < 5 or trimmed.len > storage.len) return null;
    for (trimmed, 0..) |character, index| {
        if (character == 0) return null;
        storage[index] = if (character == '/') '\\' else std.ascii.toLower(character);
    }
    var length = trimmed.len;
    while (length > 3 and storage[length - 1] == '\\') length -= 1;
    const normalized = storage[0..length];
    if (!std.ascii.endsWithIgnoreCase(normalized, ".exe")) return null;
    return normalized;
}

pub fn encode(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    if (entries.len > MAX_ENTRIES) return error.ExclusionLimitReached;
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();
    for (entries) |*entry| {
        if (entry.path_len == 0 or entry.path_len > MAX_PATH_BYTES) return error.InvalidApplicationPath;
        try payload.append(if (entry.enabled) 1 else 0);
        try appendInt(&payload, u16, entry.path_len);
        try payload.appendSlice(entry.pathSlice());
    }
    if (HEADER_SIZE + payload.items.len > MAX_FILE_SIZE) return error.ExclusionFileTooLarge;
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try output.ensureTotalCapacity(HEADER_SIZE + payload.items.len);
    try output.appendSlice(MAGIC);
    try appendInt(&output, u16, VERSION);
    try appendInt(&output, u16, @intCast(entries.len));
    try appendInt(&output, u32, @intCast(payload.items.len));
    try appendInt(&output, u32, std.hash.Crc32.hash(payload.items));
    try output.appendSlice(payload.items);
    return output.toOwnedSlice();
}

pub fn decodeInto(store: *Store, bytes: []const u8) !void {
    if (bytes.len < HEADER_SIZE or bytes.len > MAX_FILE_SIZE) return error.InvalidExclusionFile;
    if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return error.InvalidExclusionFile;
    var offset: usize = 8;
    if (try readInt(u16, bytes, &offset) != VERSION) return error.UnsupportedExclusionVersion;
    const count = try readInt(u16, bytes, &offset);
    if (count > MAX_ENTRIES) return error.InvalidExclusionFile;
    const payload_len = try readInt(u32, bytes, &offset);
    const checksum = try readInt(u32, bytes, &offset);
    if (payload_len != bytes.len - HEADER_SIZE) return error.InvalidExclusionFile;
    const payload = bytes[HEADER_SIZE..];
    if (std.hash.Crc32.hash(payload) != checksum) return error.InvalidExclusionFile;
    var payload_offset: usize = 0;
    store.count = 0;
    while (store.count < count) : (store.count += 1) {
        if (payload_offset >= payload.len) return error.InvalidExclusionFile;
        const enabled = payload[payload_offset];
        payload_offset += 1;
        if (enabled > 1) return error.InvalidExclusionFile;
        const path_len = try readInt(u16, payload, &payload_offset);
        if (path_len == 0 or path_len > MAX_PATH_BYTES or payload_offset + path_len > payload.len) return error.InvalidExclusionFile;
        var entry = &store.entries[store.count];
        @memcpy(entry.path[0..path_len], payload[payload_offset .. payload_offset + path_len]);
        entry.path_len = path_len;
        entry.enabled = enabled == 1;
        var normalized: [MAX_PATH_BYTES]u8 = undefined;
        const verified = normalizePath(entry.pathSlice(), &normalized) orelse return error.InvalidExclusionFile;
        @memcpy(entry.path[0..verified.len], verified);
        entry.path_len = @intCast(verified.len);
        payload_offset += path_len;
    }
    if (payload_offset != payload.len) return error.InvalidExclusionFile;
}

fn appendInt(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var storage: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &storage, value, .little);
    try list.appendSlice(&storage);
}

fn readInt(comptime T: type, bytes: []const u8, offset: *usize) !T {
    if (offset.* + @sizeOf(T) > bytes.len) return error.InvalidExclusionFile;
    const result = std.mem.readInt(T, bytes[offset.*..][0..@sizeOf(T)], .little);
    offset.* += @sizeOf(T);
    return result;
}
