//! Core types for the CLI framework.
//!
//! Contains the structural definitions that callers use to declare their
//! CLI layout: `App`, `Command`, `FlagDef`, `ArgDef`, `HelpSection`, and
//! the runtime `Context` passed to command handlers.

const std = @import("std");
const validate = @import("validate.zig");

// ── Argument & Flag Definitions ────────────────────────────────────────

/// A positional argument expected by a command.
pub const ArgDef = struct {
    name: []const u8,
    required: bool = false,
    description: []const u8 = "",
};

/// A named flag (--name / -x) accepted by a command or globally.
pub const FlagDef = struct {
    name: []const u8,
    short: ?u8 = null,
    default: ?[]const u8 = null,
    env: ?[]const u8 = null,
    description: []const u8 = "",
    /// If true, flag takes a value argument; if false, it's boolean.
    /// Boolean flags reject `--name=value`; use `negatable` for `--no-name`.
    takes_value: bool = true,
    /// Custom placeholder name for the value (e.g. "INTERVAL").
    value_name: []const u8 = "",
    /// Flag must be provided (or have env/default).
    required: bool = false,
    /// Names of flags that conflict with this one (mutually exclusive).
    conflicts: []const []const u8 = &.{},
    /// If true, --no-NAME is automatically accepted as the negation.
    negatable: bool = false,
};

// ── Command ────────────────────────────────────────────────────────────

/// A CLI command or subcommand with optional flags, args, and children.
pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    aliases: []const []const u8 = &.{},
    args: []const ArgDef = &.{},
    flags: []const FlagDef = &.{},
    subcommands: []const Command = &.{},
    /// If true, everything after `--` is captured as rest args.
    takes_rest: bool = false,
    /// Handler receives an explicit allocator following the unmanaged pattern
    /// (Zig stdlib direction: per-call allocator, no stored allocator field).
    run: ?*const fn (std.mem.Allocator, *Context) anyerror!void = null,

    /// Check if this command matches the given name (primary or alias).
    pub fn matches(self: *const Command, input: []const u8) bool {
        if (std.mem.eql(u8, self.name, input)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, input)) return true;
        }
        return false;
    }
};

// ── Help Layout ────────────────────────────────────────────────────────

/// A titled section in the root help output (e.g. "Access", "Topic").
pub const HelpSection = struct {
    title: []const u8,
    entries: []const HelpEntry,
};

/// A single row in a help section.
pub const HelpEntry = struct {
    label: []const u8,
    description: []const u8,
};

// ── Error Set ──────────────────────────────────────────────────────────

/// Errors that `App.run` can return.
///
/// The library writes a human-readable message to its stderr writer before
/// returning a parse error, so callers typically just map non-OOM errors
/// to a non-zero exit code.
pub const Error = error{
    UnknownFlag,
    MissingFlagValue,
    MissingRequiredFlag,
    ConflictingFlags,
    UnknownCommand,
    UnknownSubcommand,
    UnexpectedArgument,
    InvalidIntValue,
} ||
    std.mem.Allocator.Error ||
    std.Io.Writer.Error;

/// Legacy alias retained for backwards compatibility with the first draft.
pub const ParseError = Error;

// ── Runtime Context ────────────────────────────────────────────────────

/// Runtime state passed to command handlers after successful parsing.
///
/// Ownership / lifetime contract:
/// - `flags`, `positional`, `rest_args`, and `command_path` store
///   `[]const u8` slices that *borrow* from the caller-provided `args`
///   slice, the `envp` block, or the application definition. They are
///   valid only during the handler call.
/// - Handlers that need to retain a flag value or command path beyond
///   the call must `allocator.dupe(u8, ...)` it themselves.
pub const Context = struct {
    flags: std.StringHashMap([]const u8),
    positional: std.StringHashMap([]const u8),
    rest_args: std.ArrayList([]const u8),
    set_by_argv: std.StringHashMap(void),
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    envp: [*:null]const ?[*:0]const u8,
    /// Full command path, e.g. "timer add".
    command_path: []const u8,

    /// Create a new empty context.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        envp: [*:null]const ?[*:0]const u8,
    ) Context {
        return .{
            .flags = std.StringHashMap([]const u8).init(allocator),
            .positional = std.StringHashMap([]const u8).init(allocator),
            .rest_args = .empty,
            .set_by_argv = std.StringHashMap(void).init(allocator),
            .io = io,
            .stdout = stdout,
            .stderr = stderr,
            .envp = envp,
            .command_path = "",
        };
    }

    /// Release all owned resources.
    ///
    /// `flags`, `positional`, and `set_by_argv` remember their allocator;
    /// the explicit allocator is only for the unmanaged `rest_args` list.
    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        self.rest_args.deinit(allocator);
        self.set_by_argv.deinit();
        self.flags.deinit();
        self.positional.deinit();
    }

    /// Get a flag value, returning "" if absent.
    pub fn flag(self: *const Context, name: []const u8) []const u8 {
        return self.flags.get(name) orelse "";
    }

    /// Returns true if the flag was explicitly set on argv.
    pub fn hasFlag(self: *const Context, name: []const u8) bool {
        return self.set_by_argv.contains(name);
    }

    /// Record that a flag value came from argv rather than defaults/env.
    pub fn markFlagSetByArgv(self: *Context, name: []const u8) std.mem.Allocator.Error!void {
        try self.set_by_argv.put(name, {});
    }

    /// Parse a flag value as an integer, returning null if absent or empty.
    /// Returns `error.InvalidIntValue` (and writes a message to stderr) if
    /// the value is non-empty but not parseable as `T`.
    pub fn flagIntOrNull(self: *const Context, comptime T: type, name: []const u8) Error!?T {
        const value = self.flags.get(name) orelse return null;
        if (value.len == 0) return null;
        return std.fmt.parseInt(T, value, 10) catch {
            try self.stderr.print(
                "error: invalid value '{s}' for --{s}\n",
                .{ value, name },
            );
            return error.InvalidIntValue;
        };
    }

    /// Parse a flag value as an integer, returning 0 if absent or empty.
    pub fn flagInt(self: *const Context, comptime T: type, name: []const u8) Error!T {
        return (try self.flagIntOrNull(T, name)) orelse 0;
    }

    /// Parse a flag value as a boolean ("true" / "1"), or null if absent.
    pub fn flagBoolOrNull(self: *const Context, name: []const u8) ?bool {
        const value = self.flags.get(name) orelse return null;
        return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }

    /// Parse a flag value as a boolean ("true" / "1"), false if absent.
    pub fn flagBool(self: *const Context, name: []const u8) bool {
        return self.flagBoolOrNull(name) orelse false;
    }

    /// Get a positional argument by name, returning "" if absent.
    pub fn arg(self: *const Context, name: []const u8) []const u8 {
        return self.positional.get(name) orelse "";
    }

    /// Returns everything after `--` when the command has `takes_rest = true`.
    pub fn rest(self: *const Context) []const []const u8 {
        return self.rest_args.items;
    }

    /// Look up an environment variable from the envp block.
    pub fn getEnv(self: *const Context, name: []const u8) ?[]const u8 {
        return validate.lookupEnv(self.envp, name);
    }
};

// ── Resolve Result ─────────────────────────────────────────────────────

/// Outcome of command resolution: the matched command plus index
/// metadata describing where it sat in the raw argv.
///
/// Two-level command nesting is supported (top-level + one subcommand).
/// Deeper nesting is not handled by the resolver and would resolve to
/// the second-level command with extras treated as positionals.
pub const ResolveResult = struct {
    cmd: Command,
    /// Name of the top-level command when `cmd` is a subcommand;
    /// empty string when `cmd` is itself top-level.
    parent_name: []const u8,
    /// Index in raw argv where the command's own arguments begin
    /// (i.e. one past the last command word).
    args_start: usize,
    /// Index in raw argv of the top-level command word. Also the
    /// exclusive upper bound of the first pre-command global-flag region.
    cmd_pos: usize,
    /// Index in raw argv of the resolved leaf command word.
    leaf_cmd_pos: usize,
};

// ── App ────────────────────────────────────────────────────────────────

/// Top-level application definition. Delegates to parse / help / validate
/// modules through `run`.
pub const App = struct {
    name: []const u8,
    description: []const u8 = "",
    version: []const u8 = "",
    global_flags: []const FlagDef = &.{},
    commands: []const Command = &.{},
    help_sections: []const HelpSection = &.{},

    /// Parse arguments and dispatch to the matched command handler.
    ///
    /// Writes help and error output to the supplied `stdout` / `stderr`
    /// writers. The caller is responsible for flushing them after `run`
    /// returns.
    ///
    /// The return type is `anyerror` because command handler errors are
    /// forwarded verbatim. Parse-time errors before handler dispatch are
    /// members of `Error` and can still be matched by name.
    pub fn run(
        self: *const App,
        allocator: std.mem.Allocator,
        io: std.Io,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        env_block: [*:null]const ?[*:0]const u8,
        args: []const []const u8,
    ) anyerror!void {
        const parse = @import("parse.zig");
        try parse.run(allocator, io, stdout, stderr, env_block, self, args);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

fn makeContext(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Context {
    const envp: [*:null]const ?[*:0]const u8 = &.{};
    return Context.init(allocator, std.testing.io, stdout, stderr, envp);
}

test "context basics" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try ctx.flags.put("port", "8080");
    try std.testing.expectEqualStrings("8080", ctx.flag("port"));
    try std.testing.expectEqual(@as(u16, 8080), try ctx.flagInt(u16, "port"));
}

test "context flagBool" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try ctx.flags.put("verbose", "true");
    try std.testing.expect(ctx.flagBool("verbose"));
    try std.testing.expect(!ctx.flagBool("missing"));
}

test "context hasFlag distinguishes set vs absent" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try ctx.flags.put("present", "");
    try std.testing.expect(!ctx.hasFlag("present"));
    try ctx.markFlagSetByArgv("present");
    try std.testing.expect(ctx.hasFlag("present"));
    try std.testing.expect(!ctx.hasFlag("absent"));
}

test "context flag returns empty for missing" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try std.testing.expectEqualStrings("", ctx.flag("nope"));
}

test "context flagIntOrNull distinguishes missing from zero" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try std.testing.expectEqual(@as(?i32, null), try ctx.flagIntOrNull(i32, "missing"));
    try ctx.flags.put("zero", "0");
    try std.testing.expectEqual(@as(?i32, 0), try ctx.flagIntOrNull(i32, "zero"));
}

test "context flagBoolOrNull distinguishes missing from false" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try std.testing.expect(ctx.flagBoolOrNull("missing") == null);
    try ctx.flags.put("disabled", "false");
    try std.testing.expectEqual(false, ctx.flagBoolOrNull("disabled").?);
}

test "context flagInt returns 0 for missing or empty" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 0), try ctx.flagInt(u16, "nope"));
    try ctx.flags.put("empty", "");
    try std.testing.expectEqual(@as(u32, 0), try ctx.flagInt(u32, "empty"));
}

test "context flagInt returns error on invalid value" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try ctx.flags.put("port", "abc");
    try std.testing.expectError(error.InvalidIntValue, ctx.flagInt(u16, "port"));
    try std.testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "invalid value 'abc'") != null);
}

test "context rest args" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try ctx.rest_args.append(allocator, "echo");
    try ctx.rest_args.append(allocator, "hello");
    const r = ctx.rest();
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("echo", r[0]);
    try std.testing.expectEqualStrings("hello", r[1]);
}

test "context arg returns empty for missing" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    var ctx = makeContext(allocator, &out.writer, &err.writer);
    defer ctx.deinit(allocator);

    try std.testing.expectEqualStrings("", ctx.arg("missing"));
}

test "command matches primary name" {
    const cmd = Command{ .name = "create", .aliases = &.{"add"} };
    try std.testing.expect(cmd.matches("create"));
    try std.testing.expect(cmd.matches("add"));
    try std.testing.expect(!cmd.matches("delete"));
}

test "command matches without aliases" {
    const cmd = Command{ .name = "list" };
    try std.testing.expect(cmd.matches("list"));
    try std.testing.expect(!cmd.matches("ls"));
}
