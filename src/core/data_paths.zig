const std = @import("std");
const data_location = @import("data_location.zig");

pub const Mode = enum { standard, portable };

pub const DataPaths = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    root: []u8,
    profiles: []u8,
    corpus: []u8,
    control_root: []u8,
    location_status: LocationStatus = .unchanged,

    pub const LocationStatus = enum { unchanged, applied, failed };

    pub fn init(allocator: std.mem.Allocator, portable: bool) !DataPaths {
        const executable_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(executable_dir);
        if (portable) return initFromRoots(allocator, .portable, executable_dir, null);

        const local_app_data = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local_app_data);
        const default_root = try std.fs.path.join(allocator, &.{ local_app_data, "SysInput" });
        defer allocator.free(default_root);
        try std.fs.cwd().makePath(default_root);

        var current_root = (try data_location.loadActive(allocator, default_root)) orelse try allocator.dupe(u8, default_root);
        defer allocator.free(current_root);
        var location_status: LocationStatus = .unchanged;
        data_location.validateWritable(allocator, current_root) catch {
            allocator.free(current_root);
            current_root = try allocator.dupe(u8, default_root);
            location_status = .failed;
        };
        if (data_location.applyPending(allocator, default_root, default_root, current_root)) |applied| {
            if (applied) |new_root| {
                allocator.free(current_root);
                current_root = new_root;
                location_status = .applied;
            }
        } else |_| {
            location_status = .failed;
        }
        return initResolved(allocator, .standard, executable_dir, current_root, default_root, location_status);
    }

    pub fn initFromRoots(
        allocator: std.mem.Allocator,
        mode: Mode,
        executable_dir: []const u8,
        local_app_data: ?[]const u8,
    ) !DataPaths {
        const root = switch (mode) {
            .portable => try std.fs.path.join(allocator, &.{ executable_dir, "data" }),
            .standard => try std.fs.path.join(allocator, &.{ local_app_data orelse return error.MissingLocalAppData, "SysInput" }),
        };
        defer allocator.free(root);
        const control_root = try allocator.dupe(u8, root);
        defer allocator.free(control_root);
        return initResolved(allocator, mode, executable_dir, root, control_root, .unchanged);
    }

    fn initResolved(
        allocator: std.mem.Allocator,
        mode: Mode,
        executable_dir: []const u8,
        resolved_root: []const u8,
        control_directory: []const u8,
        location_status: LocationStatus,
    ) !DataPaths {
        const root = try allocator.dupe(u8, resolved_root);
        errdefer allocator.free(root);
        const control_root = try allocator.dupe(u8, control_directory);
        errdefer allocator.free(control_root);
        const profiles = try std.fs.path.join(allocator, &.{ root, "profiles" });
        errdefer allocator.free(profiles);
        const corpus = try std.fs.path.join(allocator, &.{ root, "corpus" });
        errdefer allocator.free(corpus);

        try std.fs.cwd().makePath(profiles);
        try std.fs.cwd().makePath(corpus);

        var result = DataPaths{
            .allocator = allocator,
            .mode = mode,
            .root = root,
            .profiles = profiles,
            .corpus = corpus,
            .control_root = control_root,
            .location_status = location_status,
        };
        try result.migrateLegacyProfiles(executable_dir);
        return result;
    }

    pub fn deinit(self: *DataPaths) void {
        self.allocator.free(self.root);
        self.allocator.free(self.profiles);
        self.allocator.free(self.corpus);
        self.allocator.free(self.control_root);
    }

    pub fn stageRootChange(self: *const DataPaths, target: []const u8, copy_existing: bool) !void {
        if (self.mode == .portable) return error.PortableDataDirectoryFixed;
        try data_location.stageChange(self.allocator, self.control_root, self.root, target, copy_existing);
    }

    pub fn defaultRoot(self: *const DataPaths) []const u8 {
        return self.control_root;
    }

    pub fn path(self: *const DataPaths, name: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, name });
    }

    fn migrateLegacyProfiles(self: *const DataPaths, executable_dir: []const u8) !void {
        const legacy_dir = try std.fs.path.join(self.allocator, &.{ executable_dir, "data" });
        defer self.allocator.free(legacy_dir);
        for ([_][]const u8{ "profile.bin", "context.bin", "sentences.bin" }) |name| {
            const source = try std.fs.path.join(self.allocator, &.{ legacy_dir, name });
            defer self.allocator.free(source);
            const target = try std.fs.path.join(self.allocator, &.{ self.profiles, name });
            defer self.allocator.free(target);
            // A migration problem must not remove the legacy file or prevent
            // the input assistant from starting with a fresh profile.
            copyIfMissing(source, target, self.allocator) catch {};
        }
    }
};

fn copyIfMissing(source: []const u8, target: []const u8, allocator: std.mem.Allocator) !void {
    if (std.fs.cwd().access(target, .{})) |_| return else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var input = std.fs.cwd().openFile(source, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer input.close();

    const temporary = try std.fmt.allocPrint(allocator, "{s}.migrate.tmp", .{target});
    defer allocator.free(temporary);
    var output = try std.fs.cwd().createFile(temporary, .{ .truncate = true });
    var output_open = true;
    defer if (output_open) output.close();
    errdefer std.fs.cwd().deleteFile(temporary) catch {};
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try input.read(&buffer);
        if (count == 0) break;
        try output.writeAll(buffer[0..count]);
    }
    try output.sync();
    output.close();
    output_open = false;
    std.fs.renameAbsolute(temporary, target) catch |err| switch (err) {
        error.PathAlreadyExists => std.fs.cwd().deleteFile(temporary) catch {},
        else => return err,
    };
}
