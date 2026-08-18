const std = @import("std");

const ACTIVE_MAGIC = "SYSILOC1";
const PENDING_MAGIC = "SYSIPND1";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 8 + 2 + 2 + 4;
pub const MAX_PATH_BYTES: usize = 32 * 1024;
const MAX_FILE_SIZE: usize = HEADER_SIZE + 1 + MAX_PATH_BYTES;

pub const Change = struct {
    allocator: std.mem.Allocator,
    target: []u8,
    copy_existing: bool,

    pub fn deinit(self: *Change) void {
        self.allocator.free(self.target);
    }
};

pub fn activePath(allocator: std.mem.Allocator, control_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ control_root, "data-location.bin" });
}

fn pendingPath(allocator: std.mem.Allocator, control_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ control_root, "data-location.pending" });
}

pub fn loadActive(allocator: std.mem.Allocator, control_root: []const u8) !?[]u8 {
    const path = try activePath(allocator, control_root);
    defer allocator.free(path);
    return loadPathRecord(allocator, path, ACTIVE_MAGIC, false) catch null;
}

pub fn loadPending(allocator: std.mem.Allocator, control_root: []const u8) !?Change {
    const path = try pendingPath(allocator, control_root);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_FILE_SIZE) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    const decoded = try decode(bytes, PENDING_MAGIC, true);
    return .{
        .allocator = allocator,
        .target = try allocator.dupe(u8, decoded.path),
        .copy_existing = decoded.copy_existing,
    };
}

pub fn stageChange(
    allocator: std.mem.Allocator,
    control_root: []const u8,
    current_root: []const u8,
    target: []const u8,
    copy_existing: bool,
) !void {
    if (!std.fs.path.isAbsolute(target) or target.len == 0 or target.len > MAX_PATH_BYTES) return error.InvalidDataDirectory;
    if (isFileSystemRoot(target)) return error.InvalidDataDirectory;
    if (copy_existing and isDescendant(current_root, target)) return error.TargetInsideCurrentDirectory;
    try validateWritable(allocator, target);
    if (copy_existing and !samePath(current_root, target) and try containsUserData(target)) return error.TargetDirectoryNotEmpty;

    try std.fs.cwd().makePath(control_root);
    const path = try pendingPath(allocator, control_root);
    defer allocator.free(path);
    try saveRecord(allocator, path, PENDING_MAGIC, target, copy_existing);
}

pub fn cancelPending(allocator: std.mem.Allocator, control_root: []const u8) void {
    const path = pendingPath(allocator, control_root) catch return;
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

pub fn applyPending(
    allocator: std.mem.Allocator,
    control_root: []const u8,
    default_root: []const u8,
    current_root: []const u8,
) !?[]u8 {
    var change = (loadPending(allocator, control_root) catch |err| {
        cancelPending(allocator, control_root);
        return err;
    }) orelse return null;
    defer change.deinit();
    errdefer cancelPending(allocator, control_root);

    if (!samePath(current_root, change.target) and change.copy_existing) {
        if (try containsUserData(change.target)) return error.TargetDirectoryNotEmpty;
        try copyTree(allocator, current_root, change.target);
    } else {
        try std.fs.cwd().makePath(change.target);
    }

    const active = try activePath(allocator, control_root);
    defer allocator.free(active);
    if (samePath(default_root, change.target)) {
        std.fs.cwd().deleteFile(active) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        try saveRecord(allocator, active, ACTIVE_MAGIC, change.target, false);
    }
    cancelPending(allocator, control_root);
    return try allocator.dupe(u8, change.target);
}

pub fn samePath(left: []const u8, right: []const u8) bool {
    const a = std.mem.trimRight(u8, left, "\\/");
    const b = std.mem.trimRight(u8, right, "\\/");
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isFileSystemRoot(path: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, path, "\\/");
    return trimmed.len == 2 and std.ascii.isAlphabetic(trimmed[0]) and trimmed[1] == ':';
}

fn isDescendant(parent_path: []const u8, child_path: []const u8) bool {
    const parent = std.mem.trimRight(u8, parent_path, "\\/");
    const child = std.mem.trimRight(u8, child_path, "\\/");
    return child.len > parent.len and
        std.ascii.eqlIgnoreCase(parent, child[0..parent.len]) and
        (child[parent.len] == '\\' or child[parent.len] == '/');
}

pub fn validateWritable(allocator: std.mem.Allocator, directory: []const u8) !void {
    try std.fs.cwd().makePath(directory);
    const probe_name = try std.fmt.allocPrint(allocator, ".sysinput-write-test-{d}.tmp", .{std.time.nanoTimestamp()});
    defer allocator.free(probe_name);
    const probe = try std.fs.path.join(allocator, &.{ directory, probe_name });
    defer allocator.free(probe);
    var file = try std.fs.cwd().createFile(probe, .{ .exclusive = true });
    file.close();
    try std.fs.cwd().deleteFile(probe);
}

fn containsUserData(directory_path: []const u8) !bool {
    var directory = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "data-location.bin") or
            std.mem.eql(u8, entry.name, "data-location.pending")) continue;
        return true;
    }
    return false;
}

fn copyTree(allocator: std.mem.Allocator, source_root: []const u8, target_root: []const u8) !void {
    try std.fs.cwd().makePath(target_root);
    var source = try std.fs.cwd().openDir(source_root, .{ .iterate = true });
    defer source.close();
    var walker = try source.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "data-location.bin") or
            std.mem.eql(u8, entry.path, "data-location.pending")) continue;
        const target = try std.fs.path.join(allocator, &.{ target_root, entry.path });
        defer allocator.free(target);
        switch (entry.kind) {
            .directory => try std.fs.cwd().makePath(target),
            .file => {
                const source_path = try std.fs.path.join(allocator, &.{ source_root, entry.path });
                defer allocator.free(source_path);
                try copyFileExclusive(source_path, target);
            },
            else => {},
        }
    }
}

fn copyFileExclusive(source: []const u8, target: []const u8) !void {
    if (std.fs.cwd().access(target, .{})) |_| return error.PathAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var input = try std.fs.cwd().openFile(source, .{});
    defer input.close();
    var output = try std.fs.cwd().createFile(target, .{ .exclusive = true });
    var output_open = true;
    defer if (output_open) output.close();
    errdefer std.fs.cwd().deleteFile(target) catch {};
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try input.read(&buffer);
        if (count == 0) break;
        try output.writeAll(buffer[0..count]);
    }
    try output.sync();
    output.close();
    output_open = false;
}

fn saveRecord(
    allocator: std.mem.Allocator,
    path: []const u8,
    magic: *const [8:0]u8,
    value: []const u8,
    copy_existing: bool,
) !void {
    if (value.len == 0 or value.len > MAX_PATH_BYTES or value.len + 1 > std.math.maxInt(u16)) return error.InvalidDataDirectory;
    const payload_len = value.len + 1;
    var bytes = try allocator.alloc(u8, HEADER_SIZE + payload_len);
    defer allocator.free(bytes);
    @memcpy(bytes[0..8], magic[0..8]);
    std.mem.writeInt(u16, bytes[8..10], VERSION, .little);
    std.mem.writeInt(u16, bytes[10..12], @intCast(payload_len), .little);
    bytes[HEADER_SIZE] = @intFromBool(copy_existing);
    @memcpy(bytes[HEADER_SIZE + 1 ..], value);
    std.mem.writeInt(u32, bytes[12..16], std.hash.Crc32.hash(bytes[HEADER_SIZE..]), .little);

    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    var file = try std.fs.cwd().createFile(temporary, .{ .truncate = true });
    var open = true;
    defer if (open) file.close();
    errdefer std.fs.cwd().deleteFile(temporary) catch {};
    try file.writeAll(bytes);
    try file.sync();
    file.close();
    open = false;
    try std.fs.renameAbsolute(temporary, path);
}

fn loadPathRecord(allocator: std.mem.Allocator, path: []const u8, magic: *const [8:0]u8, has_flags: bool) !?[]u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_FILE_SIZE) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    const decoded = try decode(bytes, magic, has_flags);
    return try allocator.dupe(u8, decoded.path);
}

const Decoded = struct { path: []const u8, copy_existing: bool };
fn decode(bytes: []const u8, magic: *const [8:0]u8, has_flags: bool) !Decoded {
    if (bytes.len < HEADER_SIZE + 2 or bytes.len > MAX_FILE_SIZE) return error.InvalidDataLocation;
    if (!std.mem.eql(u8, bytes[0..8], magic[0..8])) return error.InvalidDataLocation;
    if (std.mem.readInt(u16, bytes[8..10], .little) != VERSION) return error.UnsupportedDataLocationVersion;
    const payload_len = std.mem.readInt(u16, bytes[10..12], .little);
    if (payload_len < 2 or bytes.len != HEADER_SIZE + payload_len) return error.InvalidDataLocation;
    const payload = bytes[HEADER_SIZE..];
    if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, bytes[12..16], .little)) return error.InvalidDataLocation;
    const flags = payload[0];
    if ((!has_flags and flags != 0) or flags > 1) return error.InvalidDataLocation;
    const path = payload[1..];
    if (!std.fs.path.isAbsolute(path) or path.len > MAX_PATH_BYTES) return error.InvalidDataLocation;
    return .{ .path = path, .copy_existing = flags == 1 };
}
