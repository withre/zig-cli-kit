//! Validation helpers: env lookup, Levenshtein distance, flag / command
//! suggestions, required-flag checks, and conflict enforcement.
//!
//! Validators write human-readable messages to a caller-supplied stderr
//! writer and return narrow errors. They never call `std.process.exit`.

const std = @import("std");
const types = @import("types.zig");

const FlagDef = types.FlagDef;
const Command = types.Command;
const Context = types.Context;
const Error = types.Error;

const Writer = std.Io.Writer;

// ── Environment Variable Lookup ────────────────────────────────────────

/// Look up an environment variable from a null-terminated envp block.
pub fn lookupEnv(envp: [*:null]const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (envp[i]) |env_str| : (i += 1) {
        const len = std.mem.indexOfSentinel(u8, 0, env_str);
        const entry = env_str[0..len];
        if (entry.len <= name.len) continue;
        if (entry[name.len] != '=') continue;
        if (!std.mem.eql(u8, entry[0..name.len], name)) continue;
        return entry[name.len + 1 ..];
    }
    return null;
}

// ── Levenshtein Distance ───────────────────────────────────────────────

/// Stack-sized small-string fast path. Strings up to this length compute
/// the distance with no allocation.
const stack_levenshtein_max: usize = 32;

/// Compute the Levenshtein edit distance between two strings.
///
/// Uses a stack buffer for inputs up to `stack_levenshtein_max` bytes; for
/// longer inputs, allocates a temporary row from `allocator`. Returns
/// `error.OutOfMemory` if allocation fails on the slow path.
pub fn levenshteinDistance(
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
) std.mem.Allocator.Error!usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    if (b.len <= stack_levenshtein_max) {
        var prev: [stack_levenshtein_max + 1]usize = undefined;
        var curr: [stack_levenshtein_max + 1]usize = undefined;
        return levenshteinInner(a, b, prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }

    const prev = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(prev);
    const curr = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(curr);
    return levenshteinInner(a, b, prev, curr);
}

/// Core DP loop. Caller supplies two row buffers of length `b.len + 1`.
fn levenshteinInner(a: []const u8, b: []const u8, prev: []usize, curr: []usize) usize {
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev, curr);
    }
    return prev[b.len];
}

// ── Suggestion Helpers ─────────────────────────────────────────────────

/// Suggest the closest flag name (threshold < 4), or null.
///
/// On allocator failure during the long-string path, silently skips that
/// candidate; suggestions are best-effort by nature.
pub fn suggestFlag(allocator: std.mem.Allocator, input: []const u8, flags: []const FlagDef) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 4;
    for (flags) |f| {
        const dist = levenshteinDistance(allocator, input, f.name) catch continue;
        if (dist < best_dist) {
            best_dist = dist;
            best = f.name;
        }
    }
    return best;
}

/// Suggest the closest command name or alias (threshold < 4), or null.
/// Recurses into subcommands so typo'd nested commands also get hints.
pub fn suggestCommand(allocator: std.mem.Allocator, input: []const u8, commands: []const Command) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 4;
    suggestCommandInto(allocator, input, commands, &best, &best_dist);
    return best;
}

fn suggestCommandInto(
    allocator: std.mem.Allocator,
    input: []const u8,
    commands: []const Command,
    best: *?[]const u8,
    best_dist: *usize,
) void {
    for (commands) |cmd| {
        const dist = levenshteinDistance(allocator, input, cmd.name) catch continue;
        if (dist < best_dist.*) {
            best_dist.* = dist;
            best.* = cmd.name;
        }
        for (cmd.aliases) |alias| {
            const adist = levenshteinDistance(allocator, input, alias) catch continue;
            if (adist < best_dist.*) {
                best_dist.* = adist;
                best.* = alias;
            }
        }
        if (cmd.subcommands.len > 0) {
            suggestCommandInto(allocator, input, cmd.subcommands, best, best_dist);
        }
    }
}

// ── Flag Lookup ────────────────────────────────────────────────────────

/// Find a flag definition by long name.
pub fn findFlagDef(flags: []const FlagDef, name: []const u8) ?FlagDef {
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// Find a command or global flag by long name, with command flags shadowing globals.
pub fn findScopedFlag(cmd: Command, global_flags: []const FlagDef, name: []const u8) ?FlagDef {
    return findFlagDef(cmd.flags, name) orelse findFlagDef(global_flags, name);
}

/// Find a flag definition by short character.
pub fn findFlagByShort(flags: []const FlagDef, short: u8) ?FlagDef {
    for (flags) |f| {
        if (f.short == short) return f;
    }
    return null;
}

/// If `flag_name` is `"no-X"` and `X` is negatable, return `X`.
pub fn negatedName(flags: []const FlagDef, flag_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, flag_name, "no-")) return null;
    const orig = flag_name[3..];
    for (flags) |f| {
        if (f.negatable and std.mem.eql(u8, f.name, orig)) return f.name;
    }
    return null;
}

// ── Required / Conflict Validation ─────────────────────────────────────

/// Check all required flags are present. Writes an error message to
/// `stderr` and returns `error.MissingRequiredFlag` if any are missing.
pub fn validateRequired(
    stderr: *Writer,
    cmd: Command,
    global_flags: []const FlagDef,
    ctx: *const Context,
) Error!void {
    for (scopedFlagLists(cmd, global_flags)) |flags| {
        for (flags) |f| {
            if (!f.required) continue;
            const val = ctx.flags.get(f.name) orelse {
                try printRequiredError(stderr, f);
                return error.MissingRequiredFlag;
            };
            if (val.len == 0) {
                try printRequiredError(stderr, f);
                return error.MissingRequiredFlag;
            }
        }
    }
}

/// Print a "missing required flag" error with optional env hint.
fn printRequiredError(stderr: *Writer, f: FlagDef) Writer.Error!void {
    try stderr.print("error: missing required flag --{s}", .{f.name});
    if (f.env) |env_name| {
        try stderr.print(" (or set ${s})", .{env_name});
    }
    try stderr.writeAll("\n");
}

/// Check no mutually-exclusive flags are set together. Writes an error
/// message to `stderr` and returns `error.ConflictingFlags` on conflict.
pub fn validateConflicts(
    stderr: *Writer,
    cmd: Command,
    global_flags: []const FlagDef,
    ctx: *const Context,
) Error!void {
    for (scopedFlagLists(cmd, global_flags)) |flags| {
        for (flags) |f| {
            if (f.conflicts.len == 0) continue;
            if (!ctx.hasFlag(f.name)) continue;
            for (f.conflicts) |conflict_name| {
                if (!ctx.hasFlag(conflict_name)) continue;
                try stderr.print(
                    "error: --{s} and --{s} are mutually exclusive\n",
                    .{ f.name, conflict_name },
                );
                return error.ConflictingFlags;
            }
        }
    }
}

fn scopedFlagLists(cmd: Command, global_flags: []const FlagDef) [2][]const FlagDef {
    return .{ cmd.flags, global_flags };
}

/// Print an unknown-flag error with an optional "did you mean" suggestion.
pub fn printUnknownFlag(
    allocator: std.mem.Allocator,
    stderr: *Writer,
    flag_name: []const u8,
    primary_flags: []const FlagDef,
    fallback_flags: []const FlagDef,
) Writer.Error!void {
    const suggestion = suggestFlag(allocator, flag_name, primary_flags) orelse
        suggestFlag(allocator, flag_name, fallback_flags);
    if (suggestion) |sug| {
        try stderr.print("error: unknown flag '--{s}'. Did you mean '--{s}'?\n", .{ flag_name, sug });
    } else {
        try stderr.print("error: unknown flag '--{s}'\n", .{flag_name});
    }
}

/// Print an error for a value supplied to a boolean flag.
pub fn printUnexpectedFlagValue(stderr: *Writer, flag_name: []const u8) Writer.Error!void {
    try stderr.print("error: flag '--{s}' does not take a value\n", .{flag_name});
}

/// Check if a token is a recognised flag for the given command + globals.
pub fn isKnownFlag(cmd: Command, global_flags: []const FlagDef, token: []const u8) bool {
    if (!std.mem.startsWith(u8, token, "-")) return false;
    if (std.mem.startsWith(u8, token, "--")) {
        const name = token[2..];
        const bare = if (std.mem.indexOfScalar(u8, name, '=')) |eq| name[0..eq] else name;
        if (bare.len == 0) return std.mem.eql(u8, token, "--");
        return findFlagDef(cmd.flags, bare) != null or
            findFlagDef(global_flags, bare) != null or
            negatedName(cmd.flags, bare) != null or
            negatedName(global_flags, bare) != null or
            std.mem.eql(u8, bare, "help");
    }
    if (token.len >= 2) {
        const short = token[1];
        if (short == 'h') return true;
        return findFlagByShort(cmd.flags, short) != null or
            findFlagByShort(global_flags, short) != null;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "lookupEnv finds variable" {
    const env1: [*:0]const u8 = "HOME=/home/test";
    const env2: [*:0]const u8 = "EVER_PORT=9999";
    const envp: [*:null]const ?[*:0]const u8 = &.{ env1, env2, null };

    try std.testing.expectEqualStrings("/home/test", lookupEnv(envp, "HOME").?);
    try std.testing.expectEqualStrings("9999", lookupEnv(envp, "EVER_PORT").?);
    try std.testing.expect(lookupEnv(envp, "MISSING") == null);
    try std.testing.expect(lookupEnv(envp, "HOM") == null);
}

test "lookupEnv handles empty envp" {
    const envp: [*:null]const ?[*:0]const u8 = &.{null};
    try std.testing.expect(lookupEnv(envp, "ANYTHING") == null);
}

test "levenshtein distance" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try levenshteinDistance(a, "abc", "abc"));
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(a, "abc", "ab"));
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(a, "evry", "every"));
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(a, "crn", "cron"));
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance(a, "abc", "xyz"));
}

test "levenshtein empty strings" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try levenshteinDistance(a, "", ""));
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance(a, "abc", ""));
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance(a, "", "abc"));
}

test "levenshtein handles strings beyond stack fast path" {
    const a = std.testing.allocator;
    const long_a = "this-is-a-very-long-flag-name-exceeding-stack-buf";
    const long_b = "this-is-a-very-long-flag-name-exceeding-stack-buf";
    try std.testing.expectEqual(@as(usize, 0), try levenshteinDistance(a, long_a, long_b));
    const long_c = "this-is-a-very-long-flag-name-exceeding-stack-bux";
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(a, long_a, long_c));
}

test "suggestFlag finds close match" {
    const a = std.testing.allocator;
    const flags = &[_]FlagDef{
        .{ .name = "every", .description = "interval" },
        .{ .name = "cron", .description = "cron expr" },
        .{ .name = "port", .description = "port" },
    };
    try std.testing.expectEqualStrings("every", suggestFlag(a, "evry", flags).?);
    try std.testing.expectEqualStrings("cron", suggestFlag(a, "crn", flags).?);
    try std.testing.expect(suggestFlag(a, "xyzxyz", flags) == null);
}

test "suggestFlag returns null for empty flags" {
    try std.testing.expect(suggestFlag(std.testing.allocator, "test", &.{}) == null);
}

test "suggestCommand finds commands and aliases" {
    const a = std.testing.allocator;
    const cmds = &[_]Command{
        .{ .name = "topic", .aliases = &.{"tp"} },
        .{ .name = "hook" },
    };
    try std.testing.expectEqualStrings("topic", suggestCommand(a, "topi", cmds).?);
    try std.testing.expectEqualStrings("hook", suggestCommand(a, "hok", cmds).?);
    try std.testing.expect(suggestCommand(a, "zzzzzzz", cmds) == null);
}

test "suggestCommand recurses into subcommands" {
    const a = std.testing.allocator;
    const cmds = &[_]Command{
        .{ .name = "topic", .subcommands = &.{
            .{ .name = "create" },
            .{ .name = "delete" },
        } },
    };
    try std.testing.expectEqualStrings("create", suggestCommand(a, "creat", cmds).?);
    try std.testing.expectEqualStrings("delete", suggestCommand(a, "delet", cmds).?);
}

test "negatedName" {
    const flags = &[_]FlagDef{
        .{ .name = "http", .takes_value = false, .negatable = true, .description = "HTTP" },
        .{ .name = "persist", .takes_value = false, .negatable = false, .description = "persist" },
    };
    try std.testing.expectEqualStrings("http", negatedName(flags, "no-http").?);
    try std.testing.expect(negatedName(flags, "no-persist") == null);
    try std.testing.expect(negatedName(flags, "http") == null);
}

test "findFlagDef" {
    const flags = &[_]FlagDef{
        .{ .name = "port", .short = 'p', .description = "port" },
        .{ .name = "host", .description = "host" },
    };
    const found = findFlagDef(flags, "port").?;
    try std.testing.expectEqualStrings("port", found.name);
    try std.testing.expectEqual(@as(?u8, 'p'), found.short);
    try std.testing.expect(findFlagDef(flags, "missing") == null);
}

test "findFlagByShort" {
    const flags = &[_]FlagDef{
        .{ .name = "port", .short = 'p', .description = "port" },
        .{ .name = "host", .description = "host" },
    };
    try std.testing.expectEqualStrings("port", findFlagByShort(flags, 'p').?.name);
    try std.testing.expect(findFlagByShort(flags, 'x') == null);
}

test "isKnownFlag long flag" {
    const cmd = Command{ .name = "test", .flags = &.{
        .{ .name = "verbose", .takes_value = false, .description = "v" },
    } };
    const globals = &[_]FlagDef{
        .{ .name = "port", .short = 'p', .description = "port" },
    };
    try std.testing.expect(isKnownFlag(cmd, globals, "--verbose"));
    try std.testing.expect(isKnownFlag(cmd, globals, "--port"));
    try std.testing.expect(isKnownFlag(cmd, globals, "--help"));
    try std.testing.expect(!isKnownFlag(cmd, globals, "--unknown"));
    try std.testing.expect(!isKnownFlag(cmd, globals, "notaflag"));
}

test "isKnownFlag short flag" {
    const cmd = Command{ .name = "test" };
    const globals = &[_]FlagDef{
        .{ .name = "port", .short = 'p', .description = "port" },
    };
    try std.testing.expect(isKnownFlag(cmd, globals, "-p"));
    try std.testing.expect(isKnownFlag(cmd, globals, "-h"));
    try std.testing.expect(!isKnownFlag(cmd, globals, "-z"));
}

test "validateRequired returns error when command flag missing" {
    const allocator = std.testing.allocator;
    var err: Writer.Allocating = .init(allocator);
    defer err.deinit();
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();

    const cmd = Command{
        .name = "test",
        .flags = &.{.{ .name = "key", .required = true, .description = "" }},
    };
    var ctx = Context.init(allocator, std.testing.io, &out.writer, &err.writer, &.{});
    defer ctx.deinit(allocator);

    try std.testing.expectError(error.MissingRequiredFlag, validateRequired(&err.writer, cmd, &.{}, &ctx));
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "missing required flag --key") != null);
}

test "validateRequired returns error when global flag missing" {
    const allocator = std.testing.allocator;
    var err: Writer.Allocating = .init(allocator);
    defer err.deinit();
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();

    const cmd = Command{ .name = "test" };
    const globals = &[_]FlagDef{.{ .name = "token", .required = true, .description = "" }};
    var ctx = Context.init(allocator, std.testing.io, &out.writer, &err.writer, &.{});
    defer ctx.deinit(allocator);

    try std.testing.expectError(error.MissingRequiredFlag, validateRequired(&err.writer, cmd, globals, &ctx));
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "missing required flag --token") != null);
}

test "validateConflicts returns error on command conflict" {
    const allocator = std.testing.allocator;
    var err: Writer.Allocating = .init(allocator);
    defer err.deinit();
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();

    const cmd = Command{
        .name = "test",
        .flags = &.{
            .{ .name = "a", .conflicts = &.{"b"}, .description = "" },
            .{ .name = "b", .description = "" },
        },
    };
    var ctx = Context.init(allocator, std.testing.io, &out.writer, &err.writer, &.{});
    defer ctx.deinit(allocator);
    try ctx.flags.put("a", "1");
    try ctx.markFlagSetByArgv("a");
    try ctx.flags.put("b", "2");
    try ctx.markFlagSetByArgv("b");

    try std.testing.expectError(error.ConflictingFlags, validateConflicts(&err.writer, cmd, &.{}, &ctx));
}

test "validateConflicts returns error on global conflict" {
    const allocator = std.testing.allocator;
    var err: Writer.Allocating = .init(allocator);
    defer err.deinit();
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();

    const cmd = Command{
        .name = "test",
        .flags = &.{.{ .name = "execute", .takes_value = false, .description = "" }},
    };
    const globals = &[_]FlagDef{.{ .name = "dry-run", .takes_value = false, .conflicts = &.{"execute"}, .description = "" }};
    var ctx = Context.init(allocator, std.testing.io, &out.writer, &err.writer, &.{});
    defer ctx.deinit(allocator);
    try ctx.flags.put("dry-run", "true");
    try ctx.markFlagSetByArgv("dry-run");
    try ctx.flags.put("execute", "true");
    try ctx.markFlagSetByArgv("execute");

    try std.testing.expectError(error.ConflictingFlags, validateConflicts(&err.writer, cmd, globals, &ctx));
}
