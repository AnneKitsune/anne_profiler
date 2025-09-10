# Zig Profiler

A simple thread profiler for zig.

Inspired by https://crates.io/crates/thread_profiler .

Compatible with chrome://tracing .

### Usage
1. Add to your build.zig.zon dependencies.
2. Add to your import modules in build.zig.
3.
```zig
// create the profiler
var profiler = Profiler{};
defer profiler.deinit(std.testing.allocator);

const scope = profiler.startScope("test_range");
// do things here during the scope
profiler.endScope(std.testing.allocator, scope);

// save results to a writer (tsv file, buffer, etc...)
var writer = ...;
try profiler.save(&writer);
```
