//! Pre-command global flag parsing.
//!
//! Global flags may appear *before* the command word (`app --verbose
//! status`) in addition to the usual after-command position. This
//! module parses that pre-command slice; the main command-arg loop in
//! `parse/args.zig` handles the after-command region.
//!
//! Pre-command parsing is strict because these tokens are outside the
//! command-argument slice; unknown flags must be rejected here rather
//! than waiting for the main loop to see them.

const std = @import("std");
const types = @import("../types.zig");
const validate = @import("../validate.zig");
const tokens = @import("tokens.zig");

const FlagDef = types.FlagDef;
const Context = types.Context;
const ResolveResult = types.ResolveResult;

/// Parse global flags that appeared before the top-level command word
/// and between the parent command and resolved subcommand.
pub fn parsePreCmd(
    allocator: std.mem.Allocator,
    ctx: *Context,
    raw: []const []const u8,
    resolved: ResolveResult,
    global_flags: []const FlagDef,
) types.Error!void {
    std.debug.assert(resolved.cmd_pos <= resolved.leaf_cmd_pos);
    std.debug.assert(resolved.leaf_cmd_pos < raw.len);

    try parseRegion(allocator, ctx, raw, 0, resolved.cmd_pos, global_flags);
    if (resolved.leaf_cmd_pos > resolved.cmd_pos) {
        try parseRegion(allocator, ctx, raw, resolved.cmd_pos + 1, resolved.leaf_cmd_pos, global_flags);
    }
}

/// Strict left-to-right global-flag walk over `raw[start..limit]`.
///
/// Stops at the first token that's not a flag, not `--help`/`-h`, and
/// not `--`. The caller decides what to do with that token (treat it
/// as a command word, an unknown subcommand, the start of positionals,
/// etc.). Stopping early — rather than silently skipping non-flag
/// tokens — preserves argv-order error precedence: a real positional
/// won't be hidden behind a later bad flag.
pub fn parseRegion(
    allocator: std.mem.Allocator,
    ctx: *Context,
    raw: []const []const u8,
    start: usize,
    limit: usize,
    global_flags: []const FlagDef,
) types.Error!void {
    std.debug.assert(start <= limit);
    std.debug.assert(limit <= raw.len);

    var i = start;
    while (i < limit) : (i += 1) {
        const tok = raw[i];
        if (tokens.isOptionsTerminator(tok)) return;
        if (tokens.isHelpFlag(tok)) continue;
        if (tokens.isLongFlag(tok)) {
            i = try parseLong(allocator, ctx, raw, i, limit, global_flags);
        } else if (tokens.isShortFlag(tok)) {
            i = try parseShort(ctx, raw, i, limit, global_flags);
        } else {
            // Positional token: stop here. Pre-leaf regions never
            // contain positionals (the resolver placed every non-flag
            // token at the command word position), so stopping is
            // benign there; for the post-parent region, the caller
            // reports this token as an unknown subcommand.
            return;
        }
    }
}

/// Consume one `--long` global flag. `limit` is the exclusive upper
/// bound for value lookahead so we don't reach into the command region.
fn parseLong(
    allocator: std.mem.Allocator,
    ctx: *Context,
    raw: []const []const u8,
    idx: usize,
    limit: usize,
    global_flags: []const FlagDef,
) types.Error!usize {
    const long = tokens.splitLongFlag(raw[idx]) orelse {
        try validate.printUnknownFlag(allocator, ctx.stderr, raw[idx][2..], global_flags, &.{});
        return error.UnknownFlag;
    };
    const flag_name = long.name;

    // `--name=value` form: value is inside the same token.
    if (long.value) |value| {
        const fdef = validate.findFlagDef(global_flags, flag_name) orelse {
            try validate.printUnknownFlag(allocator, ctx.stderr, flag_name, global_flags, &.{});
            return error.UnknownFlag;
        };
        if (!fdef.takes_value) {
            try validate.printUnexpectedFlagValue(ctx.stderr, fdef.name);
            return error.UnexpectedArgument;
        }
        try setFlag(ctx, fdef.name, value);
        return idx;
    }

    // `--no-flag` negation of a `negatable` boolean global.
    if (validate.negatedName(global_flags, flag_name)) |orig| {
        try setFlag(ctx, orig, "false");
        return idx;
    }

    // `--flag` or `--flag VALUE` form.
    const fdef = validate.findFlagDef(global_flags, flag_name) orelse {
        try validate.printUnknownFlag(allocator, ctx.stderr, flag_name, global_flags, &.{});
        return error.UnknownFlag;
    };

    // Boolean: presence sets true.
    if (!fdef.takes_value) {
        try setFlag(ctx, fdef.name, "true");
        return idx;
    }
    // Value-taking: pull from the next token if it's still in the
    // pre-command window. Out-of-window means the resolver consumed the
    // potential value as something else, so report the flag as incomplete.
    if (idx + 1 < limit) {
        try setFlag(ctx, fdef.name, raw[idx + 1]);
        return idx + 1;
    }
    try ctx.stderr.print("error: flag '--{s}' requires a value\n", .{fdef.name});
    return error.MissingFlagValue;
}

/// Consume one short global flag: `-x`, `-xVAL`, `-x=VAL`, or `-x VAL`.
fn parseShort(
    ctx: *Context,
    raw: []const []const u8,
    idx: usize,
    limit: usize,
    global_flags: []const FlagDef,
) types.Error!usize {
    const tok = raw[idx];
    std.debug.assert(tok.len >= 2 and tok[0] == '-' and tok[1] != '-');

    const fdef = validate.findFlagByShort(global_flags, tok[1]) orelse {
        try ctx.stderr.print("error: unknown flag '-{c}'\n", .{tok[1]});
        return error.UnknownFlag;
    };

    // Boolean: presence sets true.
    if (!fdef.takes_value) {
        if (tok.len > 2) {
            try validate.printUnexpectedFlagValue(ctx.stderr, fdef.name);
            return error.UnexpectedArgument;
        }
        try setFlag(ctx, fdef.name, "true");
        return idx;
    }

    // Attached: `-pVAL` or `-p=VAL`.
    if (tok.len > 2) {
        const val = tokens.attachedShortValue(tok).?;
        try setFlag(ctx, fdef.name, val);
        return idx;
    }

    // Detached: `-p VAL`, only if a token remains in the pre-command window.
    if (idx + 1 < limit) {
        try setFlag(ctx, fdef.name, raw[idx + 1]);
        return idx + 1;
    }
    try ctx.stderr.print("error: flag '-{c}' (--{s}) requires a value\n", .{ tok[1], fdef.name });
    return error.MissingFlagValue;
}

fn setFlag(ctx: *Context, name: []const u8, value: []const u8) types.Error!void {
    try ctx.flags.put(name, value);
    try ctx.markFlagSetByArgv(name);
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// These build a minimal Context to exercise the pre-command parsing
// directly; the wider App.run integration tests in parse.zig cover the
// interactions with command resolution, defaults, and env binding.

const testing = std.testing;
const Writer = std.Io.Writer;

/// See `parse/args.zig` for the rationale on the `setup` pattern —
/// Context holds pointers into our own fields, so we must initialise
/// in place rather than returning by value.
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

test "parsePreCmd: detached `-p 9999`" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{.{ .name = "port", .short = 'p', .description = "" }};
    const raw = &[_][]const u8{ "-p", "9999", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 3, .cmd_pos = 2, .leaf_cmd_pos = 2 };

    try parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectEqualStrings("9999", tc.ctx.flag("port"));
}

test "parsePreCmd: attached `-p9999`" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{.{ .name = "port", .short = 'p', .description = "" }};
    const raw = &[_][]const u8{ "-p9999", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 2, .cmd_pos = 1, .leaf_cmd_pos = 1 };

    try parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectEqualStrings("9999", tc.ctx.flag("port"));
}

test "parsePreCmd: `--port=9999`" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{.{ .name = "port", .description = "" }};
    const raw = &[_][]const u8{ "--port=9999", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 2, .cmd_pos = 1, .leaf_cmd_pos = 1 };

    try parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectEqualStrings("9999", tc.ctx.flag("port"));
}

test "parsePreCmd: `--no-flag` negation" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{
        .{ .name = "colour", .takes_value = false, .negatable = true, .description = "" },
    };
    const raw = &[_][]const u8{ "--no-colour", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 2, .cmd_pos = 1, .leaf_cmd_pos = 1 };

    try parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectEqualStrings("false", tc.ctx.flag("colour"));
}

test "parsePreCmd: boolean global by presence" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{
        .{ .name = "verbose", .short = 'v', .takes_value = false, .description = "" },
    };
    const raw = &[_][]const u8{ "-v", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 2, .cmd_pos = 1, .leaf_cmd_pos = 1 };

    try parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectEqualStrings("true", tc.ctx.flag("verbose"));
}

test "parsePreCmd: unknown long flag is rejected" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{};
    const raw = &[_][]const u8{ "--bogus", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 2, .cmd_pos = 1, .leaf_cmd_pos = 1 };

    const result = parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectError(error.UnknownFlag, result);
    try testing.expect(std.mem.indexOf(u8, tc.err.writer.buffered(), "unknown flag '--bogus'") != null);
}

test "parsePreCmd: `--bool=value` is rejected" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{.{ .name = "verbose", .takes_value = false, .description = "" }};
    const raw = &[_][]const u8{ "--verbose=false", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 2, .cmd_pos = 1, .leaf_cmd_pos = 1 };

    const result = parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectError(error.UnexpectedArgument, result);
    try testing.expect(std.mem.indexOf(u8, tc.err.writer.buffered(), "does not take a value") != null);
}

test "parsePreCmd: short boolean with attached payload is rejected" {
    const allocator = testing.allocator;
    var tc: TestCtx = undefined;
    tc.setup(allocator);
    defer tc.deinit(allocator);

    const globals: []const FlagDef = &.{.{ .name = "verbose", .short = 'v', .takes_value = false, .description = "" }};
    const raw = &[_][]const u8{ "-vgarbage", "status" };
    const resolved: ResolveResult = .{ .cmd = .{ .name = "status" }, .parent_name = "", .args_start = 2, .cmd_pos = 1, .leaf_cmd_pos = 1 };

    const result = parsePreCmd(allocator, &tc.ctx, raw, resolved, globals);
    try testing.expectError(error.UnexpectedArgument, result);
    try testing.expect(!tc.ctx.hasFlag("verbose"));
    try testing.expect(std.mem.indexOf(u8, tc.err.writer.buffered(), "does not take a value") != null);
}
