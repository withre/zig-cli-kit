//! Argument parsing and command dispatch — orchestration layer.
//!
//! The real work happens in the sub-modules under `parse/`:
//!
//! - `parse/tokens.zig`   — token classifiers (`isLongFlag`, …)
//! - `parse/resolve.zig`  — find the deepest matching command
//! - `parse/globals.zig`  — pre-command global flag parsing
//! - `parse/args.zig`     — main command-arg loop
//!
//! This file wires those together, applies defaults / env bindings,
//! runs validation, and invokes the resolved command's handler. All
//! user-facing output goes through caller-supplied writers; parse
//! failures return narrow `Error` values, never `std.process.exit`.

const std = @import("std");
const types = @import("types.zig");
const help = @import("help.zig");
const validate = @import("validate.zig");
const tokens = @import("parse/tokens.zig");
const resolve = @import("parse/resolve.zig");
const globals = @import("parse/globals.zig");
const args_mod = @import("parse/args.zig");

const App = types.App;
const Command = types.Command;
const FlagDef = types.FlagDef;
const Context = types.Context;
const ResolveResult = types.ResolveResult;
const Error = types.Error;

const Writer = std.Io.Writer;

// ── Entry Point ────────────────────────────────────────────────────────

/// Top-level parse-and-dispatch. Called by `App.run`.
///
/// `args` is the *full* argv (program name at index 0). Help and
/// version requests are handled here and return successfully without
/// invoking any command handler.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *Writer,
    stderr: *Writer,
    env_block: [*:null]const ?[*:0]const u8,
    app: *const App,
    args: []const []const u8,
) anyerror!void {
    const raw = if (args.len > 1) args[1..] else args[0..0];
    if (raw.len == 0) {
        try help.printRootHelp(io, stdout, app);
        return;
    }

    if (try handleSpecialFirst(io, stdout, stderr, app, raw)) return;

    const resolved = try resolveOrFail(allocator, stderr, app, raw);

    var ctx = Context.init(allocator, io, stdout, stderr, env_block);
    defer ctx.deinit(allocator);
    const cmd_path = try makeCommandPath(allocator, resolved);
    defer freeCommandPath(allocator, resolved, cmd_path);
    ctx.command_path = cmd_path;

    // Flag values come from four sources, in priority order:
    //   defaults  <  env vars  <  pre-command globals  <  command-line args
    // Within defaults/env, command flags shadow globals to match argv parsing.
    try applyDefaults(&ctx, resolved.cmd.flags, app.global_flags);
    try applyEnv(&ctx, resolved.cmd.flags, app.global_flags);
    try globals.parsePreCmd(allocator, &ctx, raw, resolved, app.global_flags);

    const parent_without_run = resolved.cmd.subcommands.len > 0 and resolved.cmd.run == null;
    if (parent_without_run) {
        try globals.parseRegion(allocator, &ctx, raw, resolved.args_start, raw.len, app.global_flags);
        if (resolve.firstNonFlagArg(app, raw, resolved.args_start)) |tok| {
            try stderr.print(
                "error: unknown subcommand '{s}' for '{s}'. Run '{s} {s} --help'.\n",
                .{ tok, resolved.cmd.name, app.name, resolved.cmd.name },
            );
            return error.UnknownSubcommand;
        }
    } else {
        try args_mod.parseAll(allocator, &ctx, app, resolved.cmd, raw[resolved.args_start..]);
    }

    if (tokens.helpRequestedIn(raw)) {
        try help.printCommandHelp(io, stdout, app, resolved.cmd, resolved.parent_name);
        return;
    }

    if (parent_without_run) {
        try help.printCommandHelp(io, stdout, app, resolved.cmd, resolved.parent_name);
        return;
    }

    try validate.validateRequired(stderr, resolved.cmd, app.global_flags, &ctx);
    try validate.validateConflicts(stderr, resolved.cmd, app.global_flags, &ctx);

    if (resolved.cmd.run) |run_fn| try run_fn(allocator, &ctx);
}

fn makeCommandPath(allocator: std.mem.Allocator, resolved: ResolveResult) std.mem.Allocator.Error![]const u8 {
    if (resolved.parent_name.len == 0) return resolved.cmd.name;
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ resolved.parent_name, resolved.cmd.name });
}

fn freeCommandPath(allocator: std.mem.Allocator, resolved: ResolveResult, cmd_path: []const u8) void {
    // Only subcommand paths are allocated; top-level paths borrow Command.name.
    if (resolved.parent_name.len > 0) allocator.free(cmd_path);
}

// ── Help / version short-circuits ──────────────────────────────────────

/// Handle `help`, `--help`, `-h`, `version`, `--version` as the first
/// token after the program name. Returns true if the call was handled.
fn handleSpecialFirst(
    io: std.Io,
    stdout: *Writer,
    stderr: *Writer,
    app: *const App,
    raw: []const []const u8,
) Error!bool {
    std.debug.assert(raw.len > 0);
    const first = raw[0];
    if (tokens.isHelpToken(first)) return handleHelp(io, stdout, stderr, app, raw);
    if (tokens.isVersionToken(first)) {
        try stdout.print("{s}\n", .{app.version});
        return true;
    }
    return false;
}

/// Resolve `help <cmd>` or just `help`.
fn handleHelp(
    io: std.Io,
    stdout: *Writer,
    stderr: *Writer,
    app: *const App,
    raw: []const []const u8,
) Error!bool {
    if (raw.len == 1) {
        try help.printRootHelp(io, stdout, app);
        return true;
    }
    if (resolve.commandSkippingGlobals(app, raw[1..])) |res| {
        try help.printCommandHelp(io, stdout, app, res.cmd, res.parent_name);
        return true;
    }
    try stderr.print("error: unknown command. Run '{s} help'.\n", .{app.name});
    return error.UnknownCommand;
}

// ── Command resolution wrapper ─────────────────────────────────────────

/// Resolve a command, or write an error message and return
/// `error.UnknownCommand`.
fn resolveOrFail(
    allocator: std.mem.Allocator,
    stderr: *Writer,
    app: *const App,
    raw: []const []const u8,
) Error!ResolveResult {
    if (resolve.commandSkippingGlobals(app, raw)) |res| return res;
    const cmd_name = resolve.firstNonFlagArg(app, raw, 0) orelse {
        try stderr.print("error: missing command. Run '{s} help'.\n", .{app.name});
        return error.UnknownCommand;
    };
    if (validate.suggestCommand(allocator, cmd_name, app.commands)) |sug| {
        try stderr.print("error: unknown command '{s}'. Did you mean '{s}'?\n", .{ cmd_name, sug });
    } else {
        try stderr.print("error: unknown command '{s}'. Run '{s} help'.\n", .{ cmd_name, app.name });
    }
    return error.UnknownCommand;
}

// ── Default / env binding ──────────────────────────────────────────────

/// Seed `ctx.flags` with default values for every flag that declares one.
fn applyDefaults(
    ctx: *Context,
    cmd_flags: []const FlagDef,
    global_flags: []const FlagDef,
) std.mem.Allocator.Error!void {
    try seedDefaults(ctx, global_flags);
    try seedDefaults(ctx, cmd_flags);
}

fn seedDefaults(ctx: *Context, flags: []const FlagDef) std.mem.Allocator.Error!void {
    for (flags) |f| {
        if (f.default) |def| try ctx.flags.put(f.name, def);
    }
}

/// Overlay environment-variable bindings on top of defaults.
///
/// Reads from `ctx.envp` — the env block was captured at `Context.init`
/// time, so we don't take it as a separate argument.
fn applyEnv(
    ctx: *Context,
    cmd_flags: []const FlagDef,
    global_flags: []const FlagDef,
) std.mem.Allocator.Error!void {
    try seedEnv(ctx, global_flags);
    try seedEnv(ctx, cmd_flags);
}

fn seedEnv(ctx: *Context, flags: []const FlagDef) std.mem.Allocator.Error!void {
    for (flags) |f| {
        const env_name = f.env orelse continue;
        const val = validate.lookupEnv(ctx.envp, env_name) orelse continue;
        try ctx.flags.put(f.name, val);
    }
}

// ── Integration tests ──────────────────────────────────────────────────
//
// Unit tests for the small pieces live next to them in `parse/*.zig`.
// These tests exercise `App.run` end-to-end so a regression in the
// wiring (resolution → defaults → env → globals → args → dispatch) is
// caught at the public-API boundary.

const TestState = struct {
    handler_called: bool = false,
    seen_project: []const u8 = "",
    seen_port: []const u8 = "",
    seen_mode: []const u8 = "",
    seen_verbose: bool = false,
    seen_has_project: bool = false,
    seen_rest_len: usize = 0,
    seen_rest_first: []const u8 = "",
    command_path_buf: [128]u8 = std.mem.zeroes([128]u8),
    command_path_len: usize = 0,
};

threadlocal var test_state: TestState = .{};

fn testHandler(allocator: std.mem.Allocator, ctx: *Context) anyerror!void {
    var path_copy: std.ArrayList(u8) = .empty;
    defer path_copy.deinit(allocator);
    try path_copy.appendSlice(allocator, ctx.command_path);

    test_state.handler_called = true;
    test_state.seen_project = ctx.flag("project");
    test_state.seen_port = ctx.flag("port");
    test_state.seen_mode = ctx.flag("mode");
    test_state.seen_verbose = ctx.flagBool("verbose");
    test_state.seen_has_project = ctx.hasFlag("project");
    const rest = ctx.rest();
    test_state.seen_rest_len = rest.len;
    if (rest.len > 0) test_state.seen_rest_first = rest[0];
    test_state.command_path_len = @min(path_copy.items.len, test_state.command_path_buf.len);
    @memcpy(test_state.command_path_buf[0..test_state.command_path_len], path_copy.items[0..test_state.command_path_len]);
}

fn seenCommandPath() []const u8 {
    return test_state.command_path_buf[0..test_state.command_path_len];
}

fn makeTestApp() App {
    return .{
        .name = "demo",
        .description = "demo",
        .global_flags = &.{
            .{ .name = "project", .short = 'p', .default = "default", .description = "project" },
        },
        .commands = &.{
            .{
                .name = "status",
                .description = "status",
                .flags = &.{
                    .{ .name = "verbose", .short = 'v', .takes_value = false, .description = "v" },
                },
                .run = testHandler,
            },
        },
    };
}

const TestHarness = struct {
    out: Writer.Allocating,
    err: Writer.Allocating,

    fn init(allocator: std.mem.Allocator) TestHarness {
        return .{ .out = .init(allocator), .err = .init(allocator) };
    }
    fn deinit(self: *TestHarness) void {
        self.out.deinit();
        self.err.deinit();
    }
    fn stdoutBuf(self: *TestHarness) []const u8 {
        return self.out.writer.buffered();
    }
    fn stderrBuf(self: *TestHarness) []const u8 {
        return self.err.writer.buffered();
    }
};

test "App.run dispatches to handler with parsed flags" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = makeTestApp();
    try app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "--project", "myproj", "status", "-v" },
    );

    try std.testing.expect(test_state.handler_called);
    try std.testing.expectEqualStrings("myproj", test_state.seen_project);
    try std.testing.expect(test_state.seen_verbose);
}

test "App.run prints root help on no args" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = makeTestApp();
    try app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, &.{}, &.{"demo"});

    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stdoutBuf(), "Usage:") != null);
}

test "App.run returns UnknownCommand for typo with suggestion" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = makeTestApp();
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "statu" },
    );
    try std.testing.expectError(error.UnknownCommand, result);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "Did you mean 'status'") != null);
}

test "App.run returns UnknownFlag for typo'd flag" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = makeTestApp();
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "status", "--verbos" },
    );
    try std.testing.expectError(error.UnknownFlag, result);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown flag") != null);
}

test "App.run --help prints command help and skips handler" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = makeTestApp();
    try app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "status", "--help" },
    );

    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stdoutBuf(), "--verbose") != null);

    test_state = .{};
    var root_help = TestHarness.init(allocator);
    defer root_help.deinit();
    try app.run(allocator, std.testing.io, &root_help.out.writer, &root_help.err.writer, &.{}, &.{ "demo", "--help" });
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, root_help.stdoutBuf(), "Usage:") != null);

    const parent_app = App{
        .name = "demo",
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };

    test_state = .{};
    var parent_help = TestHarness.init(allocator);
    defer parent_help.deinit();
    try parent_app.run(allocator, std.testing.io, &parent_help.out.writer, &parent_help.err.writer, &.{}, &.{ "demo", "topic", "--help" });
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, parent_help.stdoutBuf(), "Subcommands:") != null);

    test_state = .{};
    var help_before_parent = TestHarness.init(allocator);
    defer help_before_parent.deinit();
    try parent_app.run(allocator, std.testing.io, &help_before_parent.out.writer, &help_before_parent.err.writer, &.{}, &.{ "demo", "--help", "topic" });
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, help_before_parent.stdoutBuf(), "Subcommands:") != null);
}

test "App.run does not treat --help after -- as help" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .commands = &.{.{ .name = "run", .takes_rest = true, .run = testHandler }},
    };
    try app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "run", "--", "--help" },
    );

    try std.testing.expect(test_state.handler_called);
    try std.testing.expectEqual(@as(usize, 1), test_state.seen_rest_len);
    try std.testing.expectEqualStrings("--help", test_state.seen_rest_first);
    try std.testing.expectEqualStrings("", h.stdoutBuf());
}

test "App.run parses globals between parent and subcommand" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "port", .description = "" }},
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    try app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "topic", "--port", "9999", "list" },
    );

    try std.testing.expect(test_state.handler_called);
    try std.testing.expectEqualStrings("9999", test_state.seen_port);
}

test "App.run rejects unknown pre-command flags" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = makeTestApp();
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "--bogus", "status" },
    );

    try std.testing.expectError(error.UnknownFlag, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown flag '--bogus'") != null);
}

test "App.run sets full command_path for subcommands" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    try app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, &.{}, &.{ "demo", "topic", "list" });

    try std.testing.expect(test_state.handler_called);
    try std.testing.expectEqualStrings("topic list", seenCommandPath());
}

test "App.run command defaults and env shadow globals" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const env1: [*:0]const u8 = "GLOBAL_MODE=from-global-env";
    const env2: [*:0]const u8 = "COMMAND_MODE=from-command-env";
    const envp: [*:null]const ?[*:0]const u8 = &.{ env1, env2, null };

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "mode", .env = "GLOBAL_MODE", .default = "global-default", .description = "" }},
        .commands = &.{.{
            .name = "status",
            .flags = &.{.{ .name = "mode", .env = "COMMAND_MODE", .default = "command-default", .description = "" }},
            .run = testHandler,
        }},
    };

    try app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, &.{}, &.{ "demo", "status" });
    try std.testing.expectEqualStrings("command-default", test_state.seen_mode);

    test_state = .{};
    try app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, envp, &.{ "demo", "status" });
    try std.testing.expectEqualStrings("from-command-env", test_state.seen_mode);
}

test "App.run env var overrides default but is overridden by argv" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const env1: [*:0]const u8 = "PROJECT=from-env";
    const envp: [*:null]const ?[*:0]const u8 = &.{ env1, null };

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "project", .env = "PROJECT", .default = "default", .description = "" }},
        .commands = &.{.{ .name = "status", .run = testHandler }},
    };

    // Env beats default, but does not count as explicitly set on argv.
    try app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, envp, &.{ "demo", "status" });
    try std.testing.expectEqualStrings("from-env", test_state.seen_project);
    try std.testing.expect(!test_state.seen_has_project);

    // Argv beats env and is recorded as explicitly set.
    test_state = .{};
    try app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        envp,
        &.{ "demo", "--project", "from-argv", "status" },
    );
    try std.testing.expectEqualStrings("from-argv", test_state.seen_project);
    try std.testing.expect(test_state.seen_has_project);
}

test "App.run validates required global flags" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "token", .required = true, .description = "" }},
        .commands = &.{.{ .name = "status", .run = testHandler }},
    };
    const result = app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, &.{}, &.{ "demo", "status" });

    try std.testing.expectError(error.MissingRequiredFlag, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "missing required flag --token") != null);
}

test "App.run ignores defaulted global in conflict validation" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "format", .default = "text", .description = "" }},
        .commands = &.{.{
            .name = "show",
            .flags = &.{.{ .name = "json", .takes_value = false, .conflicts = &.{"format"}, .description = "" }},
            .run = testHandler,
        }},
    };
    try app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, &.{}, &.{ "demo", "show", "--json" });

    try std.testing.expect(test_state.handler_called);
}

test "App.run validates global conflicts" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "dry-run", .takes_value = false, .conflicts = &.{"execute"}, .description = "" }},
        .commands = &.{.{
            .name = "deploy",
            .flags = &.{.{ .name = "execute", .takes_value = false, .description = "" }},
            .run = testHandler,
        }},
    };
    const result = app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, &.{}, &.{ "demo", "--dry-run", "deploy", "--execute" });

    try std.testing.expectError(error.ConflictingFlags, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "--dry-run and --execute") != null);
}

test "App.run reports missing command after value-taking global consumes final token" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = makeTestApp();
    const result = app.run(allocator, std.testing.io, &h.out.writer, &h.err.writer, &.{}, &.{ "demo", "--project", "status" });

    try std.testing.expectError(error.UnknownCommand, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "missing command") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown command '--project'") == null);
}

test "App.run rejects unknown flag in post-parent region" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "topic", "--bogus" },
    );

    try std.testing.expectError(error.UnknownFlag, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown flag '--bogus'") != null);
}

test "App.run rejects missing value for short global in post-parent region" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "topic", "-p" },
    );

    try std.testing.expectError(error.MissingFlagValue, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "requires a value") != null);
}

test "App.run rejects unknown pre-command flag even with trailing --help" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "--bogus", "topic", "--help" },
    );

    try std.testing.expectError(error.UnknownFlag, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown flag '--bogus'") != null);
}

// Regression: the parent-without-run help shortcut used to run before
// strict pre-command validation, so an unknown pre-command flag was
// silently masked by the help output.
test "App.run rejects unknown flag before parent-without-run command" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "--bogus", "topic" },
    );
    try std.testing.expectError(error.UnknownFlag, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown flag") != null);
}

// Regression: the parent-without-run handler used to look only at
// `raw[args_start]`, so an unknown subcommand sitting past inter-command
// globals was hidden by the help output.
test "App.run rejects unknown subcommand past inter-command globals" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .global_flags = &.{.{ .name = "port", .short = 'p', .description = "" }},
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "topic", "-p", "9999", "bogus" },
    );
    try std.testing.expectError(error.UnknownSubcommand, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown subcommand 'bogus'") != null);
}

// Regression: `parseRegion` used to walk past non-flag tokens to keep
// scanning, so an unknown subcommand followed by a bad flag would
// surface as `UnknownFlag` instead of `UnknownSubcommand`. Argv-order
// error precedence: the first wrong token in argv should be the one
// reported.
test "App.run reports unknown subcommand, not later bad flag" {
    const allocator = std.testing.allocator;
    test_state = .{};
    var h = TestHarness.init(allocator);
    defer h.deinit();

    const app = App{
        .name = "demo",
        .commands = &.{.{
            .name = "topic",
            .subcommands = &.{.{ .name = "list", .run = testHandler }},
        }},
    };
    const result = app.run(
        allocator,
        std.testing.io,
        &h.out.writer,
        &h.err.writer,
        &.{},
        &.{ "demo", "topic", "bogus", "--bad" },
    );
    try std.testing.expectError(error.UnknownSubcommand, result);
    try std.testing.expect(!test_state.handler_called);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "unknown subcommand 'bogus'") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.stderrBuf(), "--bad") == null);
}
