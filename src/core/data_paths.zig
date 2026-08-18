const std = @import("std");

pub const Mode = enum { standard, portable };

pub const DataPaths = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    root: []u8,
    profiles: []u8,
    corpus: []u8,

    pub fn init(allocator: std.mem.Allocator, portable: bool) !DataPaths {
        const executable_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(executable_dir);
        if (portable) return initFromRoots(allocator, .portable, executable_dir, null);

        const local_app_data = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local_app_data);
        return initFromRoots(allocator, .standard, executable_dir, local_app_data);
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
        errdefer allocator.free(root);
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
        };
        try result.migrateLegacyProfiles(executable_dir);
        return result;
    }

    pub fn deinit(self: *DataPaths) void {
        self.allocator.free(self.root);
        self.allocator.free(self.profiles);
        self.allocator.free(self.corpus);
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
