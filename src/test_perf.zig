//! Performance testing informing the choice of comptime vs runtime activation + threadlocal vs passing the struct around
//! This is what guided the choice in approach for the main lib.

// TODO unsafe get of data because a thread could be writing to it while we get without grabbing the mutex.

const std = @import("std");
const benchmark = @import("benchmark");

// results
// runtime true + indirection:  9ns
// comptime true + threadlocal: 5ns
// runtime true + threadlocal:  5ns
// comptime false + any:        0ns
// runtime false + threadlocal: 2ns
// runtime false + indirection: 2ns

const TestContainer = struct {
    mutex: std.Thread.Mutex = .{},
    data: std.AutoHashMapUnmanaged(std.Thread.Id, TestThreadData) = .empty,
    enabled: bool = true,
    const S = @This();
    pub fn deinit(s: *S, allocator: std.mem.Allocator) void {
        var iter = s.data.iterator();
        while (iter.next()) |pair| {
            pair.value_ptr.deinit(allocator);
        }
        s.data.deinit(allocator);
    }
};

const TestThreadData = struct {
    data: std.ArrayListUnmanaged(TestRange) = .empty,
    const S = @This();
    pub fn deinit(s: *S, allocator: std.mem.Allocator) void {
        s.data.deinit(allocator);
    }
};

const TestRange = struct {
    one: []const u8 = "abc",
    two: i128 = 55,
    three: i128 = 56,
};

// unsafe: lifetime is equal to the thread's lifetime. so if a thread exits, this becomes a dangling pointer.
var test_registry: std.AutoHashMapUnmanaged(std.Thread.Id, *const TestThreadData) = .empty;
var test_registry_mutex: std.Thread.Mutex = .{};
threadlocal var test_thread_local_data: TestThreadData = .{};
threadlocal var test_registered = false;
var test_should_profile = true;

test "bench runtime decision true indirection" {
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            var container = TestContainer{};
            defer container.deinit(std.testing.allocator);

            container.enabled = true;

            // do not optimize
            asm volatile (""
                :
                : [_] "r,m" (container.enabled),
                : .{ .memory = true });

            while (ctx.run()) {
                if (container.enabled) {
                    container.mutex.lock();
                    if (container.data.getPtr(std.Thread.getCurrentId())) |contained| {
                        @branchHint(.likely);
                        contained.data.append(std.testing.allocator, .{}) catch {};
                    } else {
                        var contained: TestThreadData = .{};
                        contained.data.append(std.testing.allocator, .{}) catch {};
                        container.data.put(std.testing.allocator, std.Thread.getCurrentId(), contained) catch {};
                    }
                    container.mutex.unlock();
                }
            }
        }
    }.bench;
    benchmark.benchmark("Bench indirection", b);
}

test "bench comptime decision threadlocal" {
    test_thread_local_data = .{};
    test_registry = .empty;
    test_registered = false;
    defer test_thread_local_data.deinit(std.testing.allocator);
    defer test_registry.deinit(std.testing.allocator);
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            while (ctx.run()) {
                // ensure registered
                if (!test_registered) {
                    @branchHint(.unlikely);
                    test_registry_mutex.lock();
                    test_registry.put(std.testing.allocator, std.Thread.getCurrentId(), &test_thread_local_data) catch {};
                    test_registry_mutex.unlock();
                    test_registered = true;
                }

                test_thread_local_data.data.append(std.testing.allocator, .{}) catch {};
            }
        }
    }.bench;
    benchmark.benchmark("Bench threadlocal", b);
}

test "bench runtime decision true threadlocal" {
    test_thread_local_data = .{};
    test_registry = .empty;
    test_should_profile = true;
    test_registered = false;
    // do not optimize
    asm volatile (""
        :
        : [_] "r,m" (test_should_profile),
        : .{ .memory = true });
    defer test_thread_local_data.deinit(std.testing.allocator);
    defer test_registry.deinit(std.testing.allocator);
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            while (ctx.run()) {
                if (test_should_profile) {
                    // ensure registered
                    if (!test_registered) {
                        @branchHint(.unlikely);
                        test_registry_mutex.lock();
                        test_registry.put(std.testing.allocator, std.Thread.getCurrentId(), &test_thread_local_data) catch {};
                        test_registry_mutex.unlock();
                        test_registered = true;
                    }
                    test_thread_local_data.data.append(std.testing.allocator, .{}) catch {};
                }
            }
        }
    }.bench;
    benchmark.benchmark("Bench runtime decision true threadlocal", b);
}

test "bench runtime decision false threadlocal" {
    test_thread_local_data = .{};
    test_registry = .empty;
    test_should_profile = false;
    test_registered = false;
    // do not optimize
    asm volatile (""
        :
        : [_] "r,m" (test_should_profile),
        : .{ .memory = true });
    defer test_thread_local_data.deinit(std.testing.allocator);
    defer test_registry.deinit(std.testing.allocator);
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            while (ctx.run()) {
                if (test_should_profile) {
                    // ensure registered
                    if (!test_registered) {
                        @branchHint(.unlikely);
                        test_registry_mutex.lock();
                        test_registry.put(std.testing.allocator, std.Thread.getCurrentId(), &test_thread_local_data) catch {};
                        test_registry_mutex.unlock();
                        test_registered = true;
                    }
                    test_thread_local_data.data.append(std.testing.allocator, .{}) catch {};
                }
            }
        }
    }.bench;
    benchmark.benchmark("Bench runtime decision false threadlocal", b);
}
