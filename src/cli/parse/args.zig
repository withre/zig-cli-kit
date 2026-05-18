//! Main command-arg loop.
//!
//! Walks the argv slice that begins *after* the resolved command word,
//! consuming long flags, short flags, `--flag=value`, `--no-X`
//! negations, the `--` separator, and positionals.
//!
//! Unlike the pre-command pass in `parse/globals.zig`, this loop is
//! strict: unknown flags and overflow positionals are user errors.

const std = @import("std");
const types = @import("../types.zig");
const validate = @import("../validate.zig");
const tokens = @import("tokens.zig");

const App = types.App;
const Command = types.Command;
const Context = types.Context;
const Error = types.Error;

const Writer = std.Io.Writer;

// ── Entry ──────────────────────────────────────────────────────────────

/// Parse flags and positional args from `args`, where `args` is the
/// argv slice starting one past the deepest command word.
pub fn parseAll(
    allocator: std.mem.Allocator,
    ctx: *Context,
    app: *const App,
    cmd: Command,
    args: []const []const u8,
) Error!void {
    var i: usize = 0;
    var pos_idx: usize = 0;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tokens.isOptionsTerminator(tok)) {
            try afterTerminator(allocator, ctx, cmd, args[i + 1 ..], &pos_idx);
            return;
        }
        if (tokens.isHelpFlag(tok)) continue;
        if (tokens.isLongFlag(tok)) {
            i = try parseLong(allocator, ctx, app, cmd, args, i);
        } else if (tokens.isShortFlag(tok)) {
            i = try parseShort(ctx, app, cmd, args, i);
        } else {
            try parsePositional(ctx, cmd, tok, &pos_idx);
        }
    }
}

// ── `--` separator ─────────────────────────────────────────────────────

/// Handle tokens after `--`. Two modes:
///
/// - Rest-capture (`cmd.takes_rest = true`): hand everything to the
///   command verbatim via `ctx.rest_args` (e.g. `run -- echo hi`).
/// - Positional-overflow: continue filling positional slots. Useful
///   when a positional value would otherwise be parsed as a flag, e.g.
///   `mv -- --weird-filename dest`. Overflow is treated the same as in
///   the non-`--` path: it's an error, not a silent drop.
fn afterTerminator(
    allocator: std.mem.Allocator,
    ctx: *Context,
    cmd: Command,
    rest: []const []const u8,
    pos_idx: *usize,
) Error!void {
    if (cmd.takes_rest) {
        for (rest) |r| try ctx.rest_args.append(allocator, r);
        return;
    }
    for (rest) |r| try parsePositional(ctx, cmd, r, pos_idx);
}

// ── Long flags ─────────────────────────────────────────────────────────

/// Consume one `--long` flag.
///
/// Command flags shadow globals (a command can legitimately re-use a
/// global name with different semantics).
fn parseLong(
    allocator: std.mem.Allocator,
    ctx: *Context,
    app: *const App,
    cmd: Command,
    args: []const []const u8,
    idx: usize,
) Error!usize {
    const long = tokens.splitLongFlag(args[idx]) orelse {
        try validate.printUnknownFlag(allocator, ctx.stderr, args[idx][2..], cmd.flags, app.global_flags);
        return error.UnknownFlag;
    };
    const flag_name = long.name;

    // `--flag=value` form.
    if (long.value) |value|
        return parseLongEq(allocator, ctx, app, cmd, flag_name, value, idx);

    // `--no-X` negation. Check command flags first to honour shadowing.
    if (validate.negatedName(cmd.flags, flag_name)) |orig| {
        try setFlag(ctx, orig, "false");
        return idx;
    }
    if (validate.negatedName(app.global_flags, flag_name)) |orig| {
        try setFlag(ctx, orig, "false");
        return idx;
    }

    const fd = validate.findFlagDef(cmd.flags, flag_name) orelse
        validate.findFlagDef(app.global_flags, flag_name) orelse
        {
            try validate.printUnknownFlag(allocator, ctx.stderr, flag_name, cmd.flags, app.global_flags);
            return error.UnknownFlag;
        };

    // Boolean: presence sets true.
    if (!fd.takes_value) {
        try setFlag(ctx, fd.name, "true");
        return idx;
    }

    // Value-taking: consume the next token, but only if it doesn't
    // itself look like a known flag — otherwise `--out --verbose`
    // would silently absorb `--verbose` as the value of `--out`.
    if (idx + 1 < args.len and !validate.isKnownFlag(cmd, app.global_flags, args[idx + 1])) {
        try setFlag(ctx, fd.name, args[idx + 1]);
        return idx + 1;
    }
    try ctx.stderr.print("error: flag '--{s}' requires a value\n", .{fd.name});
    return error.MissingFlagValue;
}

/// `--name=value` form. Returns `idx` unchanged (single token).
fn parseLongEq(
    allocator: std.mem.Allocator,
    ctx: *Context,
    app: *const App,
    cmd: Command,
    name: []const u8,
    value: []const u8,
    idx: usize,
) Error!usize {
    const fd = validate.findScopedFlag(cmd, app.global_flags, name) orelse {
        try validate.printUnknownFlag(allocator, ctx.stderr, name, cmd.flags, app.global_flags);
        return error.UnknownFlag;
    };
    if (!fd.takes_value) {
        try validate.printUnexpectedFlagValue(ctx.stderr, fd.name);
        return error.UnexpectedArgument;
    }
    try setFlag(ctx, fd.name, value);
    return idx;
}

// ── Short flags ────────────────────────────────────────────────────────

/// Consume one short flag: `-x`, `-xVAL`, `-x=VAL`, or `-x VAL`.
fn parseShort(
    ctx: *Context,
    app: *const App,
    cmd: Command,
    args: []const []const u8,
    idx: usize,
) Error!usize {
    const tok = args[idx];
    std.debug.assert(tok.len >= 2 and tok[0] == '-' and tok[1] != '-');

    const short = tok[1];
    const fd = validate.findFlagByShort(cmd.flags, short) orelse
        validate.findFlagByShort(app.global_flags, short) orelse
        {
            try ctx.stderr.print("error: unknown flag '-{c}'\n", .{short});
            return error.UnknownFlag;
        };

    // Boolean: presence sets true.
    if (!fd.takes_value) {
        if (tok.len > 2) {
            try validate.printUnexpectedFlagValue(ctx.stderr, fd.name);
            return error.UnexpectedArgument;
        }
        try setFlag(ctx, fd.name, "true");
        return idx;
    }

    // Attached: `-pVAL` or `-p=VAL`.
    if (tok.len > 2) {
        const val = tokens.attachedShortValue(tok).?;
        try setFlag(ctx, fd.name, val);
        return idx;
    }

    // Detached: `-p VAL`. Unlike `parseLong` we *do* swallow a
    // flag-shaped next token here. `-n -5` (a negative number as the
    // value of `-n`) is a common pattern, and refusing it would be
    // worse than the rare typo case.
    if (idx + 1 < args.len) {
        try setFlag(ctx, fd.name, args[idx + 1]);
        return idx + 1;
    }
    try ctx.stderr.print("error: flag '-{c}' (--{s}) requires a value\n", .{ short, fd.name });
    return error.MissingFlagValue;
}

fn setFlag(ctx: *Context, name: []const u8, value: []const u8) Error!void {
    try ctx.flags.put(name, value);
    try ctx.markFlagSetByArgv(name);
}

// ── Positionals ────────────────────────────────────────────────────────

/// Place `tok` in the next available positional slot, or fail with
/// `error.UnexpectedArgument` if all slots are full.
fn parsePositional(ctx: *Context, cmd: Command, tok: []const u8, pos_idx: *usize) Error!void {
    if (pos_idx.* < cmd.args.len) {
        try ctx.positional.put(cmd.args[pos_idx.*].name, tok);
        pos_idx.* += 1;
        return;
    }
    try ctx.stderr.print("error: unexpected argument '{s}'\n", .{tok});
    return error.UnexpectedArgument;
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// Behavioural edge cases for the main loop. Whole-app behaviour
// (resolution + defaults + env + dispatch) is covered by the
// integration tests in parse.zig.

const testing = std.testing;

/// Test fixture that bundles a Context with backing stdout/stderr
/// buffers. Must be initialised in place via `setup` because Context
/// stores pointers into our own fields — returning by value from a
/// factory would leave those pointers dangling after the move.
const TestCtx = struct {
    ctx: Context,
    out: Writer.Allocating,
    err: Writer.Allocating,

    fn setup(self: *TestCtx, allocator: std.mem.Allocator) void {
        self.out = .init(allocator);
        self.err = .init(allocator);
        self.ctx = Context.init(allocator, testing.io, &self.out.writer, &self.err.writer, &.{});
    }

    fn deinit(self: *TestCtx, allocator: std.mem.Allocator) void {
        self.ctx.deinit(allocator);
        self.out.deinit();
        self.err.deinit();
    }
};

test "parseAll: long flag with detached value" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "out", .description = "" }},
    };

    try parseAll(allocator, &tc.ctx, &app, cmd, &.{ "--out", "result.txt" });
    try testing.expectEqualStrings("result.txt", tc.ctx.flag("out"));
}

test "parseAll: long flag refuses flag-shaped value" {
    // Guards against `--out --verbose` silently absorbing `--verbose`.
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{
            .{ .name = "out", .description = "" },
            .{ .name = "verbose", .takes_value = false, .description = "" },
        },
    };

    const result = parseAll(allocator, &tc.ctx, &app, cmd, &.{ "--out", "--verbose" });
    try testing.expectError(error.MissingFlagValue, result);
}

test "parseAll: short flag accepts flag-shaped value (e.g. negative number)" {
    // `-n -5` should set n to "-5", not error.
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "n", .short = 'n', .description = "" }},
    };

    try parseAll(allocator, &tc.ctx, &app, cmd, &.{ "-n", "-5" });
    try testing.expectEqualStrings("-5", tc.ctx.flag("n"));
}

test "parseAll: attached short value `-p9999`" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
    };

    try parseAll(allocator, &tc.ctx, &app, cmd, &.{"-p9999"});
    try testing.expectEqualStrings("9999", tc.ctx.flag("port"));
}

test "parseAll: `--name=value`" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "port", .description = "" }},
    };

    try parseAll(allocator, &tc.ctx, &app, cmd, &.{"--port=9999"});
    try testing.expectEqualStrings("9999", tc.ctx.flag("port"));
}

test "parseAll: `--bool=value` is rejected" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "verbose", .takes_value = false, .description = "" }},
    };

    const result = parseAll(allocator, &tc.ctx, &app, cmd, &.{"--verbose=false"});
    try testing.expectError(error.UnexpectedArgument, result);
    try testing.expect(std.mem.indexOf(u8, tc.err.writer.buffered(), "does not take a value") != null);
}

test "parseAll: short boolean with attached payload is rejected" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "verbose", .short = 'v', .takes_value = false, .description = "" }},
    };

    const result = parseAll(allocator, &tc.ctx, &app, cmd, &.{"-v=false"});
    try testing.expectError(error.UnexpectedArgument, result);
    try testing.expect(!tc.ctx.hasFlag("verbose"));
    try testing.expect(std.mem.indexOf(u8, tc.err.writer.buffered(), "does not take a value") != null);
}

test "parseAll: `--no-X` negation" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "colour", .takes_value = false, .negatable = true, .description = "" }},
    };

    try parseAll(allocator, &tc.ctx, &app, cmd, &.{"--no-colour"});
    try testing.expectEqualStrings("false", tc.ctx.flag("colour"));
}

test "parseAll: positional overflow errors" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .args = &.{.{ .name = "src" }},
    };

    const result = parseAll(allocator, &tc.ctx, &app, cmd, &.{ "a", "b" });
    try testing.expectError(error.UnexpectedArgument, result);
}

test "parseAll: overflow after `--` errors too (no silent drop)" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .args = &.{.{ .name = "src" }},
    };

    const result = parseAll(allocator, &tc.ctx, &app, cmd, &.{ "--", "a", "b" });
    try testing.expectError(error.UnexpectedArgument, result);
}

test "parseAll: rest capture with `takes_rest`" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{ .name = "c", .takes_rest = true };

    try parseAll(allocator, &tc.ctx, &app, cmd, &.{ "--", "echo", "hello" });
    const rest = tc.ctx.rest();
    try testing.expectEqual(@as(usize, 2), rest.len);
    try testing.expectEqualStrings("echo", rest[0]);
    try testing.expectEqualStrings("hello", rest[1]);
}

test "parseAll: unknown flag returns suggestion" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const app: App = .{ .name = "t" };
    const cmd: Command = .{
        .name = "c",
        .flags = &.{.{ .name = "verbose", .takes_value = false, .description = "" }},
    };

    const result = parseAll(allocator, &tc.ctx, &app, cmd, &.{"--verbos"});
    try testing.expectError(error.UnknownFlag, result);
    try testing.expect(std.mem.indexOf(u8, tc.err.writer.buffered(), "Did you mean '--verbose'") != null);
}
