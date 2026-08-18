const std = @import("std");

pub const MAX_ENTRIES: usize = 2000;
pub const MAX_TRIGGER_BYTES: usize = 32;
pub const MAX_EXPANSION_BYTES: usize = 256;
const MAGIC = "SYSIABR1";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 8 + 2 + 4 + 4;
const MAX_FILE_SIZE: usize = 1024 * 1024;

pub const Entry = struct {
    trigger: [MAX_TRIGGER_BYTES]u8 = undefined,
    trigger_len: u8 = 0,
    expansion: [MAX_EXPANSION_BYTES]u8 = undefined,
    expansion_len: u16 = 0,
    enabled: bool = true,
    case_sensitive: bool = false,
    accepted_count: u32 = 0,
    last_used: i64 = 0,

    pub fn triggerSlice(self: *const Entry) []const u8 {
        return self.trigger[0..self.trigger_len];
    }
    pub fn expansionSlice(self: *const Entry) []const u8 {
        return self.expansion[0..self.expansion_len];
    }
};

pub const Match = struct {
    trigger: [MAX_TRIGGER_BYTES]u8 = undefined,
    trigger_len: u8 = 0,
    expansion: [MAX_EXPANSION_BYTES]u8 = undefined,
    expansion_len: u16 = 0,

    pub fn triggerSlice(self: *const Match) []const u8 {
        return self.trigger[0..self.trigger_len];
    }
    pub fn expansionSlice(self: *const Match) []const u8 {
        return self.expansion[0..self.expansion_len];
    }
};

pub const LoadStatus = enum { loaded, missing, corrupt };

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    temporary_path: []u8,
    entries: std.ArrayList(Entry),
    mutex: std.Thread.Mutex = .{},
    revision: u64 = 0,
    saved_revision: u64 = 0,

    pub fn initAt(allocator: std.mem.Allocator, directory: []const u8) !struct { store: Store, status: LoadStatus } {
        try std.fs.cwd().makePath(directory);
        const path = try std.fs.path.join(allocator, &.{ directory, "abbreviations.bin" });
        errdefer allocator.free(path);
        const temporary_path = try std.fs.path.join(allocator, &.{ directory, "abbreviations.bin.tmp" });
        errdefer allocator.free(temporary_path);
        var store = Store{ .allocator = allocator, .path = path, .temporary_path = temporary_path, .entries = std.ArrayList(Entry).init(allocator) };
        errdefer store.deinit();
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_FILE_SIZE) catch |err| switch (err) {
            error.FileNotFound => return .{ .store = store, .status = .missing },
            else => return err,
        };
        defer allocator.free(bytes);
        store.decode(bytes) catch {
            store.entries.clearRetainingCapacity();
            return .{ .store = store, .status = .corrupt };
        };
        return .{ .store = store, .status = .loaded };
    }

    pub fn deinit(self: *Store) void {
        self.entries.deinit();
        self.allocator.free(self.path);
        self.allocator.free(self.temporary_path);
    }

    pub fn lookup(self: *Store, input: []const u8) ?Match {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.findIndex(input) orelse return null;
        const entry = &self.entries.items[index];
        if (!entry.enabled) return null;
        if (entry.case_sensitive and !std.mem.eql(u8, entry.triggerSlice(), input)) return null;
        var result = Match{};
        result.trigger_len = entry.trigger_len;
        result.expansion_len = entry.expansion_len;
        @memcpy(result.trigger[0..entry.trigger_len], entry.triggerSlice());
        @memcpy(result.expansion[0..entry.expansion_len], entry.expansionSlice());
        return result;
    }

    /// Inserts or replaces a trigger. Trigger identity is ASCII case-insensitive.
    pub fn upsert(self: *Store, trigger: []const u8, expansion: []const u8, enabled: bool, case_sensitive: bool) !bool {
        try validate(trigger, expansion);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findIndex(trigger)) |index| {
            setEntry(&self.entries.items[index], trigger, expansion, enabled, case_sensitive);
            self.revision +%= 1;
            return true;
        }
        if (self.entries.items.len >= MAX_ENTRIES) return error.TooManyAbbreviations;
        var entry = Entry{};
        setEntry(&entry, trigger, expansion, enabled, case_sensitive);
        const position = self.insertionIndex(trigger);
        try self.entries.insert(position, entry);
        self.revision +%= 1;
        return false;
    }

    pub fn remove(self: *Store, index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return error.InvalidIndex;
        _ = self.entries.orderedRemove(index);
        self.revision +%= 1;
    }

    pub fn setEnabled(self: *Store, index: usize, enabled: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return error.InvalidIndex;
        self.entries.items[index].enabled = enabled;
        self.revision +%= 1;
    }

    pub fn clearStatistics(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            entry.accepted_count = 0;
            entry.last_used = 0;
        }
        self.revision +%= 1;
    }

    pub fn recordAccepted(self: *Store, trigger: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.findIndex(trigger) orelse return;
        self.entries.items[index].accepted_count +|= 1;
        self.entries.items[index].last_used = std.time.milliTimestamp();
        self.revision +%= 1;
    }

    pub fn copyEntries(self: *Store, output: *[MAX_ENTRIES]Entry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(output.len, self.entries.items.len);
        @memcpy(output[0..count], self.entries.items[0..count]);
        return count;
    }

    pub fn importTsv(self: *Store, file_path: []const u8) !usize {
        const contents = try std.fs.cwd().readFileAlloc(self.allocator, file_path, MAX_FILE_SIZE);
        defer self.allocator.free(contents);
        var imported: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\n");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const trigger = fields.next() orelse continue;
            const expansion = fields.next() orelse continue;
            const enabled_text = fields.next() orelse "1";
            const case_text = fields.next() orelse "0";
            _ = try self.upsert(trigger, expansion, !std.mem.eql(u8, enabled_text, "0"), std.mem.eql(u8, case_text, "1"));
            imported += 1;
        }
        return imported;
    }

    pub fn exportTsv(self: *Store, file_path: []const u8) !void {
        var copied: [MAX_ENTRIES]Entry = undefined;
        const count = self.copyEntries(&copied);
        var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("# trigger\texpansion\tenabled\tcase_sensitive\n");
        for (copied[0..count]) |*entry| {
            if (std.mem.indexOfAny(u8, entry.expansionSlice(), "\t\r\n") != null) continue;
            try file.writer().print("{s}\t{s}\t{d}\t{d}\n", .{ entry.triggerSlice(), entry.expansionSlice(), @intFromBool(entry.enabled), @intFromBool(entry.case_sensitive) });
        }
    }

    pub fn saveIfDirty(self: *Store, force: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!force and self.revision == self.saved_revision) return;
        try self.saveLocked();
    }

    fn saveLocked(self: *Store) !void {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        try payload.writer().writeInt(u16, @intCast(self.entries.items.len), .little);
        for (self.entries.items) |*entry| {
            try payload.append(entry.trigger_len);
            try payload.writer().writeInt(u16, entry.expansion_len, .little);
            try payload.append((if (entry.enabled) @as(u8, 1) else 0) | (if (entry.case_sensitive) @as(u8, 2) else 0));
            try payload.writer().writeInt(u32, entry.accepted_count, .little);
            try payload.writer().writeInt(i64, entry.last_used, .little);
            try payload.appendSlice(entry.triggerSlice());
            try payload.appendSlice(entry.expansionSlice());
        }
        var file = try std.fs.cwd().createFile(self.temporary_path, .{ .truncate = true });
        var open = true;
        defer if (open) file.close();
        errdefer std.fs.cwd().deleteFile(self.temporary_path) catch {};
        try file.writeAll(MAGIC);
        try file.writer().writeInt(u16, VERSION, .little);
        try file.writer().writeInt(u32, @intCast(payload.items.len), .little);
        try file.writer().writeInt(u32, std.hash.Crc32.hash(payload.items), .little);
        try file.writeAll(payload.items);
        try file.sync();
        file.close();
        open = false;
        try std.fs.renameAbsolute(self.temporary_path, self.path);
        self.saved_revision = self.revision;
    }

    fn decode(self: *Store, bytes: []const u8) !void {
        if (bytes.len < HEADER_SIZE or !std.mem.eql(u8, bytes[0..8], MAGIC)) return error.InvalidAbbreviationFile;
        if (std.mem.readInt(u16, bytes[8..10], .little) != VERSION) return error.InvalidAbbreviationFile;
        const payload_len = std.mem.readInt(u32, bytes[10..14], .little);
        if (bytes.len != HEADER_SIZE + payload_len) return error.InvalidAbbreviationFile;
        const payload = bytes[HEADER_SIZE..];
        if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, bytes[14..18], .little)) return error.InvalidAbbreviationFile;
        if (payload.len < 2) return error.InvalidAbbreviationFile;
        const count = std.mem.readInt(u16, payload[0..2], .little);
        if (count > MAX_ENTRIES) return error.InvalidAbbreviationFile;
        var offset: usize = 2;
        try self.entries.ensureTotalCapacity(count);
        for (0..count) |_| {
            if (offset + 16 > payload.len) return error.InvalidAbbreviationFile;
            const trigger_len = payload[offset];
            const expansion_len = std.mem.readInt(u16, @ptrCast(payload[offset + 1 .. offset + 3]), .little);
            const flags = payload[offset + 3];
            const accepted = std.mem.readInt(u32, @ptrCast(payload[offset + 4 .. offset + 8]), .little);
            const last_used = std.mem.readInt(i64, @ptrCast(payload[offset + 8 .. offset + 16]), .little);
            offset += 16;
            if (trigger_len == 0 or trigger_len > MAX_TRIGGER_BYTES or expansion_len == 0 or expansion_len > MAX_EXPANSION_BYTES or offset + trigger_len + expansion_len > payload.len) return error.InvalidAbbreviationFile;
            var entry = Entry{ .trigger_len = trigger_len, .expansion_len = expansion_len, .enabled = flags & 1 != 0, .case_sensitive = flags & 2 != 0, .accepted_count = accepted, .last_used = last_used };
            @memcpy(entry.trigger[0..trigger_len], payload[offset..][0..trigger_len]);
            offset += trigger_len;
            @memcpy(entry.expansion[0..expansion_len], payload[offset..][0..expansion_len]);
            offset += expansion_len;
            if (self.entries.items.len > 0 and compareFolded(self.entries.items[self.entries.items.len - 1].triggerSlice(), entry.triggerSlice()) != .lt) return error.InvalidAbbreviationFile;
            self.entries.appendAssumeCapacity(entry);
        }
        if (offset != payload.len) return error.InvalidAbbreviationFile;
        self.saved_revision = self.revision;
    }

    fn findIndex(self: *Store, trigger: []const u8) ?usize {
        const index = self.insertionIndex(trigger);
        if (index < self.entries.items.len and compareFolded(self.entries.items[index].triggerSlice(), trigger) == .eq) return index;
        return null;
    }
    fn insertionIndex(self: *Store, trigger: []const u8) usize {
        var low: usize = 0;
        var high = self.entries.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (compareFolded(self.entries.items[mid].triggerSlice(), trigger) == .lt) low = mid + 1 else high = mid;
        }
        return low;
    }
};

fn validate(trigger: []const u8, expansion: []const u8) !void {
    if (trigger.len == 0 or trigger.len > MAX_TRIGGER_BYTES) return error.InvalidTrigger;
    if (expansion.len == 0 or expansion.len > MAX_EXPANSION_BYTES) return error.InvalidExpansion;
    for (trigger) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return error.InvalidTrigger;
}

fn setEntry(entry: *Entry, trigger: []const u8, expansion: []const u8, enabled: bool, case_sensitive: bool) void {
    entry.trigger_len = @intCast(trigger.len);
    entry.expansion_len = @intCast(expansion.len);
    @memcpy(entry.trigger[0..trigger.len], trigger);
    @memcpy(entry.expansion[0..expansion.len], expansion);
    entry.enabled = enabled;
    entry.case_sensitive = case_sensitive;
}

fn compareFolded(left: []const u8, right: []const u8) std.math.Order {
    const count = @min(left.len, right.len);
    for (left[0..count], right[0..count]) |a, b| {
        const la = std.ascii.toLower(a);
        const lb = std.ascii.toLower(b);
        if (la < lb) return .lt;
        if (la > lb) return .gt;
    }
    return std.math.order(left.len, right.len);
}

pub fn explicitTrigger(text: []const u8, prefix: u8) ?[]const u8 {
    if (text.len < 3 or text[text.len - 1] != ' ') return null;
    var start = text.len - 1;
    while (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or text[start - 1] == '_' or text[start - 1] == '-')) start -= 1;
    if (start == 0 or text[start - 1] != prefix) return null;
    const trigger = text[start .. text.len - 1];
    if (trigger.len == 0 or trigger.len > MAX_TRIGGER_BYTES) return null;
    return trigger;
}
