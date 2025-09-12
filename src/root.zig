const std = @import("std");
const Mutex = std.Thread.Mutex;

const benchmark = @import("benchmark");

/// A profiled length of time.
const ProfileScope = struct {
    name: []const u8 = "",
    // using u64 instead of u128 saves 6ns per scope.
    start_time: u64 = 0,
    end_time: u64 = 0,

    const S = @This();

    /// Starts profiling a time range until .end is called.
    /// Name must live for the entire program duration.
    pub fn begin(name: []const u8) S {
        return .{
            .name = name,
            .start_time = @truncate(@as(u128, @intCast(std.time.nanoTimestamp()))),
            .end_time = 0,
        };
    }

    /// Stops profiling the range.
    pub fn end(s: *S) void {
        const end_time: u64 = @truncate(@as(u128, @intCast(std.time.nanoTimestamp())));
        s.end_time = end_time;
    }
};

/// Thread-specific profile scopes.
const ThreadProfileData = struct {
    ranges: std.ArrayListUnmanaged(ProfileScope) = .empty,
    const S = @This();
    pub fn deinit(s: *S, allocator: std.mem.Allocator) void {
        s.ranges.deinit(allocator);
    }
};

/// All functions are safe to call in a multithreaded context due to the internal mutex and atomics.
/// However, avoid direct field access.
pub const Profiler = struct {
    /// Mutex locked only when writing to `data`.
    /// `enabled is an atomic instead.
    mutex: std.Thread.Mutex = .{},
    /// The internal thread-specific profiling data.
    data: std.AutoHashMapUnmanaged(std.Thread.Id, ThreadProfileData) = .empty,
    /// Use atomic operations to touch this if stuff is happening in parallel.
    /// Prefer using the `enable` and `disable` functions.
    enabled: bool = true,

    const S = @This();
    const empty: S = .{};

    /// Enables profiling.
    pub fn enable(s: *S) void {
        @atomicStore(bool, &s.enabled, true, .release);
    }

    /// Disables profiling.
    pub fn disable(s: *S) void {
        @atomicStore(bool, &s.enabled, false, .release);
    }

    /// Starts profiling a named scope / range / length of time.
    /// End with `endScope`.
    pub fn startScope(s: *const S, name: []const u8) ProfileScope {
        if (!@atomicLoad(bool, &s.enabled, .acquire)) return .{ .name = name };

        return .begin(name);
    }

    /// Ends the profiling of a named scope / range / length of time and saves it internally.
    /// To export / save everything, use the `save` function.
    /// # Errors
    /// No errors are returned. However, if the allocator runs out of memory, no data will be written and the scope will be ignored.
    /// It is made this way to play nice with fixed buffer allocators, for when you want to limit how much memory the profiler may use.
    pub fn endScope(s: *const S, allocator: std.mem.Allocator, scope: ProfileScope) void {
        if (!@atomicLoad(bool, &s.enabled, .acquire)) return;

        var scope_copy = scope;
        scope_copy.end();

        if (scope_copy.start_time == 0) {
            @branchHint(.cold);
            // In case s.enabled got swapped on midway through a profile scope.
            scope_copy.start_time = scope_copy.end_time;
        }

        // Safe due to using a mutex.
        const s2: *S = @constCast(s);

        // Get ThreadProfileData for this thread, create it if it doesn't exist and write data.
        s2.mutex.lock();
        var thread_profile_data = s2.data.getOrPut(allocator, std.Thread.getCurrentId()) catch return;
        if (!thread_profile_data.found_existing) {
            @branchHint(.cold);
            thread_profile_data.value_ptr.* = .{};
        }
        thread_profile_data.value_ptr.ranges.append(allocator, scope_copy) catch {};
        s2.mutex.unlock();
    }

    /// Writes all the internal data to the writer in tsv format.
    /// # Errors
    /// Writer errors can happen.
    pub fn save(s: *const S, writer: *std.Io.Writer) !void {
        try writer.print("thread_id\trange_name\trange_start_nano\trange_end_nano\n", .{});

        // Safe due to using a mutex.
        const s2: *S = @constCast(s);

        s2.mutex.lock();
        defer s2.mutex.unlock();

        var it = s2.data.iterator();
        while (it.next()) |pair| {
            const thread_id = pair.key_ptr.*;
            for (pair.value_ptr.*.ranges.items) |range| {
                try writer.print("{}\t{s}\t{}\t{}\n", .{ thread_id, range.name, range.start_time, range.end_time });
            }
        }
        try writer.flush();
    }

    pub fn deinit(s: *S, allocator: std.mem.Allocator) void {
        var iter = s.data.iterator();
        while (iter.next()) |pair| {
            pair.value_ptr.*.deinit(allocator);
        }
        s.data.deinit(allocator);
    }
};

// c functions
export fn profiler_init() ?*anyopaque {
    const prof = std.heap.c_allocator.create(Profiler) catch return null;
    prof.* = Profiler.empty;
    return prof;
}

export fn profiler_deinit(prof: *anyopaque) void {
    var profiler: *Profiler = @ptrCast(@alignCast(prof));
    profiler.deinit(std.heap.c_allocator);
}

export fn profiler_scope_start(prof: *anyopaque, name: [*c]const u8) ?*anyopaque {
    var profiler: *Profiler = @ptrCast(@alignCast(prof));
    const name_slice = name[0..std.mem.indexOfSentinel(u8, 0, name)];

    const ret = std.heap.c_allocator.create(ProfileScope) catch return null;
    ret.* = profiler.startScope(name_slice);
    return ret;
}

export fn profiler_scope_end(prof: *anyopaque, scope: *anyopaque) void {
    var profiler: *Profiler = @ptrCast(@alignCast(prof));
    const scope2: *ProfileScope = @ptrCast(@alignCast(scope));
    profiler.endScope(std.heap.c_allocator, scope2.*);
}

/// Saves the profile as a tsv file in the given path relative to the current directory.
/// # Errors
/// - 0: Ok
/// - 1: Failed to create file
/// - 2: Failed to write to file
export fn profiler_save(prof: *anyopaque, path: [*c]const u8) c_int {
    var profiler: *Profiler = @ptrCast(@alignCast(prof));

    var buf: [4096]u8 = undefined;

    const path_slice = path[0..std.mem.indexOfSentinel(u8, 0, path)];
    var file = std.fs.cwd().createFile(path_slice, .{}) catch return 1;
    defer file.close();

    var writer = file.writer(&buf);

    profiler.save(&writer.interface) catch return 2;

    return 0;
}

test "c fns" {
    const prof = profiler_init().?;
    const scope = profiler_scope_start(prof, "test_scope").?;
    profiler_scope_end(prof, scope);
    try std.testing.expectEqual(0, profiler_save(prof, "test.tsv"));
}

test "profiler" {
    var profiler = Profiler{};
    defer profiler.deinit(std.testing.allocator);
    {
        const scope = profiler.startScope("test_range");
        profiler.endScope(std.testing.allocator, scope);
    }

    const range = profiler.data.get(std.Thread.getCurrentId()).?.ranges.items[0];
    try std.testing.expectEqual("test_range", range.name);
    try std.testing.expect(range.end_time >= range.start_time);

    var save_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(save_buf[0..]);
    try profiler.save(&writer);
    try std.testing.expect(writer.end > 100);
}

test "profiler disable middle" {
    var profiler = Profiler.empty;
    defer profiler.deinit(std.testing.allocator);

    const scope = profiler.startScope("test_range");
    profiler.disable();
    profiler.endScope(std.testing.allocator, scope);

    try std.testing.expectEqual(null, profiler.data.get(std.Thread.getCurrentId()));
}

test "profiler enable middle" {
    var profiler = Profiler.empty;
    defer profiler.deinit(std.testing.allocator);
    profiler.disable();

    const scope = profiler.startScope("test_range");
    profiler.enable();
    profiler.endScope(std.testing.allocator, scope);

    const range = profiler.data.get(std.Thread.getCurrentId()).?.ranges.items[0];
    try std.testing.expectEqual("test_range", range.name);
    try std.testing.expectEqual(range.end_time, range.start_time);
    try std.testing.expect(range.end_time != 0);
}

test "bench profiler enabled" {
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            var profiler = Profiler.empty;
            defer profiler.deinit(std.testing.allocator);

            while (ctx.run()) {
                const scope = profiler.startScope("");
                defer profiler.endScope(std.testing.allocator, scope);
            }
        }
    }.bench;
    benchmark.benchmark("Bench profiler enabled", b);
}

test "bench profiler disabled" {
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            var profiler = Profiler.empty;
            defer profiler.deinit(std.testing.allocator);

            profiler.disable();

            while (ctx.run()) {
                const scope = profiler.startScope("");
                defer profiler.endScope(std.testing.allocator, scope);
            }
        }
    }.bench;
    benchmark.benchmark("Bench profiler disabled", b);
}

test "import" {
    _ = @import("test_perf.zig");
}
