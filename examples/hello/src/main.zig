//! Hello-world example for zig-cli-kit, demonstrating the canonical
//! `pub fn main(init: std.process.Init)` entry point against the library.
//!
//! Build and run from this directory:
//!
//!     zig build run -- --project demo status
//!     zig build run -- status        # uses the default `--project`
//!     zig build run -- --help        # show root help
//!
//! Or from the repository root, treating this as a smoke test:
//!
//!     cd examples/hello && zig build run -- status
//!
//! See `../../README.org` for the explanation.

const std = @import("std");
const cli = @import("zig-cli-kit");

fn handleStatus(allocator: std.mem.Allocator, ctx: *cli.Context) !void {
    _ = allocator;
    try ctx.stdout.print("status: project={s}\n", .{ctx.flag("project")});
}

const app: cli.App = .{
    .name = "hello",
    .description = "hello example for zig-cli-kit",
    .global_flags = &.{
        .{
            .name = "project",
            .short = 'p',
            .default = "default",
            .env = "PROJECT",
            .description = "Project name",
        },
    },
    .commands = &.{
        .{
            .name = "status",
            .description = "Show status",
            .run = handleStatus,
        },
    },
};

pub fn main(init: std.process.Init) !void {
    // Buffered writers for stdout / stderr. The library never touches
    // global stdio, so the caller owns the buffers and the flush.
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);
    defer stdout.interface.flush() catch {};
    defer stderr.interface.flush() catch {};

    // Materialise the argv iterator into the `[]const []const u8` the
    // library expects. Zig's iterator already handles WASI/Windows quirks.
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iter.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(init.gpa);
    while (args_iter.next()) |arg| try args.append(init.gpa, arg);

    app.run(
        init.gpa,
        init.io,
        &stdout.interface,
        &stderr.interface,
        environBlockPtr(init.minimal.environ.block),
        args.items,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => std.process.exit(1),
    };
}

fn environBlockPtr(block: anytype) [*:null]const ?[*:0]const u8 {
    const T = @TypeOf(block);
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice) return block.ptr;
        },
        .@"struct" => {
            if (@hasField(T, "slice")) return block.slice.ptr;
        },
        else => {},
    }
    return block.ptr;
}
