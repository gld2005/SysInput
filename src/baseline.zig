const std = @import("std");

pub const sysinput = @import("exports.zig");

const dictionary = sysinput.text.dictionary;
const autocomplete = sysinput.text.autocomplete;

const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
};

extern "kernel32" fn GetCurrentProcess() callconv(.C) *anyopaque;
extern "psapi" fn GetProcessMemoryInfo(
    process: *anyopaque,
    counters: *PROCESS_MEMORY_COUNTERS,
    size: u32,
) callconv(.C) i32;

fn workingSetBytes() ?usize {
    var counters = std.mem.zeroes(PROCESS_MEMORY_COUNTERS);
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
    if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0) return null;
    return counters.working_set_size;
}

fn freeSuggestionItems(allocator: std.mem.Allocator, suggestions: *std.ArrayList([]const u8)) void {
    for (suggestions.items) |item| allocator.free(item);
    suggestions.clearRetainingCapacity();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var timer = try std.time.Timer.start();
    var words = try dictionary.Dictionary.init(allocator);
    defer words.deinit();
    const dictionary_load_ns = timer.read();

    var engine = try autocomplete.AutocompleteEngine.init(allocator, &words);
    defer engine.deinit();

    var learned_buf: [64]u8 = undefined;
    timer.reset();
    for (0..1000) |index| {
        const learned = try std.fmt.bufPrint(&learned_buf, "baselineword{d}", .{index});
        try engine.addWord(learned);
    }
    const learn_1000_ns = timer.read();

    const prefixes = [_][]const u8{ "th", "pre", "con", "auto", "sys", "hel", "wor", "int" };
    var suggestions = std.ArrayList([]const u8).init(allocator);
    defer {
        freeSuggestionItems(allocator, &suggestions);
        suggestions.deinit();
    }

    const query_count: usize = 1000;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    for (0..query_count) |index| {
        engine.setCurrentWord(prefixes[index % prefixes.len]);
        timer.reset();
        try engine.getSuggestions(&suggestions);
        const elapsed = timer.read();
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
        total_ns += elapsed;
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\SysInput prediction microbenchmark
        \\dictionary_words={d}
        \\dictionary_load_ms={d:.3}
        \\learn_1000_words_ms={d:.3}
        \\suggestion_queries={d}
        \\suggestion_avg_ms={d:.3}
        \\suggestion_min_ms={d:.3}
        \\suggestion_max_ms={d:.3}
        \\working_set_mib={d:.3}
        \\
    , .{
        words.word_map.count(),
        @as(f64, @floatFromInt(dictionary_load_ns)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(learn_1000_ns)) / std.time.ns_per_ms,
        query_count,
        @as(f64, @floatFromInt(total_ns / query_count)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(min_ns)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(max_ns)) / std.time.ns_per_ms,
        if (workingSetBytes()) |bytes|
            @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)
        else
            0.0,
    });
}
