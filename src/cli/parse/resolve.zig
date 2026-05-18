//! Command resolution: walk the raw argv, skipping any interleaved
//! global flags, and find the deepest matching `Command`.
//!
//! Resolution only *counts* tokens — it never stores flag values. The
//! main parser in `parse/args.zig` re-walks the same argv later and is
//! responsible for the real bookkeeping.
//!
//! Only two levels of command nesting are recognised (top-level + one
//! subcommand). The library could grow to arbitrary depth later by
//! making `matchAt` recurse into `findSub` recursively.

const std = @import("std");
const types = @import("../types.zig");
const validate = @import("../validate.zig");
const tokens = @import("tokens.zig");

const App = types.App;
const Command = types.Command;
const ResolveResult = types.ResolveResult;

// ── Public API ─────────────────────────────────────────────────────────

/// Walk `raw` and return the deepest matching command, skipping any
/// global flags that appear before or between command words.
pub fn commandSkippingGlobals(app: *const App, raw: []const []const u8) ?ResolveResult {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (tokens.isFlagShaped(raw[i])) {
            i = skipGlobalFlag(app, raw, i);
            continue;
        }
        return matchAt(app, raw, i);
    }
    return null;
}

/// Return the first non-flag token in `raw[start..]`, skipping known
/// global flags (and their values). Used both to produce "unknown
/// command 'X'" messages and to find an unknown subcommand that sits
/// past inter-command global flags.
pub fn firstNonFlagArg(app: *const App, raw: []const []const u8, start: usize) ?[]const u8 {
    std.debug.assert(start <= raw.len);
    var i = start;
    while (i < raw.len) : (i += 1) {
        if (!tokens.isFlagShaped(raw[i])) return raw[i];
        i = skipGlobalFlag(app, raw, i);
    }
    return null;
}

/// Given that `raw[idx]` looks like a flag, return the index of the
/// last token consumed by that global flag (so the caller's `+= 1`
/// lands on the next unrelated token).
///
/// Returns `idx` unchanged if the token doesn't match any known global
/// flag, or if it's a single-token form (`--flag=value`, `-pVAL`, or
/// `--no-flag`).
pub fn skipGlobalFlag(app: *const App, raw: []const []const u8, idx: usize) usize {
    std.debug.assert(idx < raw.len);
    const tok = raw[idx];
    std.debug.assert(tokens.isFlagShaped(tok));

    if (tokens.isLongFlag(tok)) return skipLongGlobal(app, idx, tok);
    if (tokens.isShortFlag(tok)) return skipShortGlobal(app, idx, tok);
    // Bare `-` or `--` falls through: no global flag matched, single token.
    return idx;
}

// ── Internal helpers ───────────────────────────────────────────────────

fn skipLongGlobal(app: *const App, idx: usize, tok: []const u8) usize {
    const long = tokens.splitLongFlag(tok) orelse return idx;
    // `--name=value`: value lives inside `tok`, no extra arg to skip.
    if (long.value != null) return idx;
    // `--flag VALUE` consumes two tokens; bare `--flag` (boolean) one.
    if (validate.findFlagDef(app.global_flags, long.name)) |fdef|
        return if (fdef.takes_value) idx + 1 else idx;
    // `--no-flag` is a single-token negation.
    if (validate.negatedName(app.global_flags, long.name) != null) return idx;
    return idx;
}

fn skipShortGlobal(app: *const App, idx: usize, tok: []const u8) usize {
    std.debug.assert(tok.len >= 2 and tok[0] == '-' and tok[1] != '-');
    // Attached forms (`-pVAL`, `-p=VAL`) are a single token, so we only
    // need to count the detached `-p VAL` case as consuming an extra.
    if (tokens.attachedShortValue(tok) != null) return idx;
    const fdef = validate.findFlagByShort(app.global_flags, tok[1]) orelse return idx;
    return if (fdef.takes_value) idx + 1 else idx;
}

/// Try to match a top-level command at `raw[idx]`, then optionally
/// descend exactly one subcommand level.
fn matchAt(app: *const App, raw: []const []const u8, idx: usize) ?ResolveResult {
    const tok = raw[idx];
    for (app.commands) |cmd| {
        if (!cmd.matches(tok)) continue;
        if (cmd.subcommands.len > 0) {
            if (findSub(app, cmd, raw, idx + 1)) |sub| return sub;
        }
        return .{
            .cmd = cmd,
            .parent_name = "",
            .args_start = idx + 1,
            .cmd_pos = idx,
            .leaf_cmd_pos = idx,
        };
    }
    return null;
}

/// Find a subcommand under `parent` somewhere in `raw[start..]`,
/// skipping any global flags between the parent and the subcommand.
fn findSub(app: *const App, parent: Command, raw: []const []const u8, start: usize) ?ResolveResult {
    std.debug.assert(start > 0);

    var j = start;
    while (j < raw.len) : (j += 1) {
        if (tokens.isFlagShaped(raw[j])) {
            j = skipGlobalFlag(app, raw, j);
            continue;
        }
        for (parent.subcommands) |sub| {
            if (sub.matches(raw[j])) return .{
                .cmd = sub,
                .parent_name = parent.name,
                .args_start = j + 1,
                // Top-level command lives at `start - 1`; globals can
                // appear before it and between it and this leaf command.
                .cmd_pos = start - 1,
                .leaf_cmd_pos = j,
            };
        }
        // First non-flag token wasn't a subcommand — stop scanning so
        // the caller can treat the parent itself as the resolved cmd.
        break;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "commandSkippingGlobals finds a simple command" {
    const app: App = .{ .name = "test", .commands = &.{.{ .name = "status" }} };
    const res = commandSkippingGlobals(&app, &.{"status"}).?;
    try std.testing.expectEqualStrings("status", res.cmd.name);
    try std.testing.expectEqual(@as(usize, 1), res.args_start);
    try std.testing.expectEqual(@as(usize, 0), res.cmd_pos);
}

test "commandSkippingGlobals skips a value-taking global before the command" {
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
        .commands = &.{.{ .name = "status" }},
    };
    const res = commandSkippingGlobals(&app, &.{ "-p", "9999", "status" }).?;
    try std.testing.expectEqualStrings("status", res.cmd.name);
    try std.testing.expectEqual(@as(usize, 2), res.cmd_pos);
}

test "commandSkippingGlobals handles attached short global (`-p9999`)" {
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
        .commands = &.{.{ .name = "status" }},
    };
    const res = commandSkippingGlobals(&app, &.{ "-p9999", "status" }).?;
    try std.testing.expectEqualStrings("status", res.cmd.name);
    try std.testing.expectEqual(@as(usize, 1), res.cmd_pos);
}

test "commandSkippingGlobals handles `--name=value` global" {
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .description = "" }},
        .commands = &.{.{ .name = "status" }},
    };
    const res = commandSkippingGlobals(&app, &.{ "--port=9999", "status" }).?;
    try std.testing.expectEqualStrings("status", res.cmd.name);
    try std.testing.expectEqual(@as(usize, 1), res.cmd_pos);
}

test "commandSkippingGlobals descends into subcommands" {
    const app: App = .{
        .name = "test",
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list" }},
        }},
    };
    const res = commandSkippingGlobals(&app, &.{ "topic", "list" }).?;
    try std.testing.expectEqualStrings("list", res.cmd.name);
    try std.testing.expectEqualStrings("topic", res.parent_name);
    try std.testing.expectEqual(@as(usize, 0), res.cmd_pos);
    try std.testing.expectEqual(@as(usize, 1), res.leaf_cmd_pos);
}

test "commandSkippingGlobals records top and leaf positions around interleaved globals" {
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list" }},
        }},
    };
    const res = commandSkippingGlobals(&app, &.{ "topic", "-p", "9999", "list" }).?;
    try std.testing.expectEqualStrings("list", res.cmd.name);
    try std.testing.expectEqual(@as(usize, 0), res.cmd_pos);
    try std.testing.expectEqual(@as(usize, 3), res.leaf_cmd_pos);
    try std.testing.expectEqual(@as(usize, 4), res.args_start);
}

test "commandSkippingGlobals returns null for unknown command" {
    const app: App = .{ .name = "test", .commands = &.{.{ .name = "status" }} };
    try std.testing.expect(commandSkippingGlobals(&app, &.{"bogus"}) == null);
}

test "firstNonFlagArg returns command token after skipping globals" {
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
    };
    try std.testing.expectEqualStrings(
        "status",
        firstNonFlagArg(&app, &.{ "-p", "9999", "status" }, 0).?,
    );
}

test "firstNonFlagArg returns null when only flags present" {
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
    };
    try std.testing.expect(firstNonFlagArg(&app, &.{ "-p", "9999" }, 0) == null);
}

test "firstNonFlagArg with non-zero start skips parent and inter-command globals" {
    // Used by parent-without-run handling to find an unknown subcommand
    // sitting past `parent <globals> bogus`.
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
    };
    const raw = &[_][]const u8{ "topic", "-p", "9999", "bogus" };
    try std.testing.expectEqualStrings("bogus", firstNonFlagArg(&app, raw, 1).?);
}

test "firstNonFlagArg agrees with commandSkippingGlobals on the skipped span" {
    // If both walkers see the same input, they should agree on which
    // token is the first non-flag — this property catches future drift
    // between the two skip codepaths.
    const app: App = .{
        .name = "test",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
        .commands = &.{.{ .name = "status" }},
    };
    const raw = &[_][]const u8{ "-p", "9999", "status" };
    const found = firstNonFlagArg(&app, raw, 0).?;
    const resolved = commandSkippingGlobals(&app, raw).?;
    try std.testing.expectEqualStrings(found, raw[resolved.cmd_pos]);
}
