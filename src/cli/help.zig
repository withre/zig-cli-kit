//! Help output formatting: root help, per-command help, flag/arg
//! label rendering. Uses `colour.Palette` — never raw escape codes.
//!
//! All output is written through a caller-supplied `*std.Io.Writer`; this
//! module never touches `std.debug.print` or process stdio directly.

const std = @import("std");
const types = @import("types.zig");
const colour = @import("colour.zig");

const App = types.App;
const Command = types.Command;
const FlagDef = types.FlagDef;
const ArgDef = types.ArgDef;

const Writer = std.Io.Writer;

// ── Root Help ──────────────────────────────────────────────────────────

/// Print the top-level usage / section listing for the whole app.
pub fn printRootHelp(io: std.Io, w: *Writer, app: *const App) Writer.Error!void {
    const p = colour.detect(io);

    try w.print("{s}{s}{s} — {s}{s}{s}\n\n", .{
        p.title, app.name, p.reset, p.desc, app.description, p.reset,
    });
    try w.print("Usage: {s} [global options] <command> [options]\n", .{app.name});

    try printGlobalFlags(w, app, p);
    try printHelpSections(w, app, p);

    try w.print("\n{s}Run '{s} <command> --help' for more information.{s}\n", .{
        p.desc, app.name, p.reset,
    });
}

/// Print global flags block (shared by root and command help).
fn printGlobalFlags(w: *Writer, app: *const App, p: colour.Palette) Writer.Error!void {
    if (app.global_flags.len == 0) return;
    try w.print("\n{s}Global Flags:{s}\n", .{ p.section, p.reset });
    for (app.global_flags) |f| try printFlagHelp(w, f, p);
}

/// Print custom help sections defined on the app.
fn printHelpSections(w: *Writer, app: *const App, p: colour.Palette) Writer.Error!void {
    if (app.help_sections.len == 0) return;
    for (app.help_sections) |sec| {
        try w.print("\n{s}{s}:{s}\n", .{ p.section, sec.title, p.reset });
        for (sec.entries) |entry| {
            try w.print("  {s}{s:<17}{s}{s}{s}{s}\n", .{
                p.cmd, entry.label, p.reset, p.desc, entry.description, p.reset,
            });
        }
    }
}

// ── Command Help ───────────────────────────────────────────────────────

/// Print full help for a single command (description, usage, flags, etc.).
pub fn printCommandHelp(
    io: std.Io,
    w: *Writer,
    app: *const App,
    cmd: Command,
    parent_name: []const u8,
) Writer.Error!void {
    const p = colour.detect(io);

    try printCmdDescription(w, cmd, parent_name, p);
    try printCmdUsage(w, app, cmd, parent_name, p);
    try printCmdAliases(w, cmd, p);
    try printCmdSubcommands(w, app, cmd, parent_name, p);

    if (cmd.subcommands.len > 0) return;

    try printCmdArguments(w, cmd, p);
    try printCmdFlags(w, cmd, p);

    if (app.global_flags.len > 0) {
        try w.print("\n{s}Global Flags:{s}\n", .{ p.section, p.reset });
        for (app.global_flags) |f| try printFlagHelp(w, f, p);
    }
}

/// Print the one-line command description.
fn printCmdDescription(w: *Writer, cmd: Command, parent: []const u8, p: colour.Palette) Writer.Error!void {
    if (parent.len > 0) {
        try w.print("{s}{s} {s}{s} — {s}{s}{s}\n", .{
            p.cmd, parent, cmd.name, p.reset, p.desc, cmd.description, p.reset,
        });
    } else {
        try w.print("{s}{s}{s} — {s}{s}{s}\n", .{
            p.cmd, cmd.name, p.reset, p.desc, cmd.description, p.reset,
        });
    }
}

/// Print the "Usage:" block for a command.
fn printCmdUsage(w: *Writer, app: *const App, cmd: Command, parent: []const u8, p: colour.Palette) Writer.Error!void {
    try w.print("\nUsage:\n", .{});
    if (cmd.subcommands.len > 0) {
        try printUsageWithSubcmds(w, app, cmd, parent);
        return;
    }
    try printUsageLeaf(w, app, cmd, parent, p);
}

/// Usage line for a command that has subcommands.
fn printUsageWithSubcmds(w: *Writer, app: *const App, cmd: Command, parent: []const u8) Writer.Error!void {
    if (parent.len > 0) {
        try w.print("  {s} {s} {s} <subcommand> [OPTIONS]\n", .{ app.name, parent, cmd.name });
    } else {
        try w.print("  {s} {s} <subcommand> [OPTIONS]\n", .{ app.name, cmd.name });
    }
}

/// Usage line for a leaf command (no subcommands).
fn printUsageLeaf(w: *Writer, app: *const App, cmd: Command, parent: []const u8, p: colour.Palette) Writer.Error!void {
    if (parent.len > 0) {
        try w.print("  {s} {s} {s}", .{ app.name, parent, cmd.name });
    } else {
        try w.print("  {s} {s}", .{ app.name, cmd.name });
    }
    if (cmd.flags.len > 0 or app.global_flags.len > 0)
        try w.writeAll(" [OPTIONS]");

    for (cmd.args) |a| try printArgInUsage(w, a, p);

    if (cmd.takes_rest) try w.writeAll(" [-- ARGS...]");
    try w.writeAll("\n");
}

/// Print a single positional arg token in the usage line.
fn printArgInUsage(w: *Writer, a: ArgDef, p: colour.Palette) Writer.Error!void {
    if (a.required) {
        try w.print(" {s}", .{p.cmd});
        try w.writeByte('<');
        try writeUppercase(w, a.name);
        try w.writeByte('>');
        try w.print("{s}", .{p.reset});
    } else {
        try w.print(" [{s}", .{p.cmd});
        try writeUppercase(w, a.name);
        try w.print("{s}]", .{p.reset});
    }
}

/// Print aliases line.
fn printCmdAliases(w: *Writer, cmd: Command, p: colour.Palette) Writer.Error!void {
    if (cmd.aliases.len == 0) return;
    try w.print("\n{s}Aliases:{s} ", .{ p.section, p.reset });
    for (cmd.aliases, 0..) |alias, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}{s}{s}", .{ p.cmd, alias, p.reset });
    }
    try w.writeAll("\n");
}

/// Print subcommands section (and "Run … --help" hint).
fn printCmdSubcommands(w: *Writer, app: *const App, cmd: Command, parent: []const u8, p: colour.Palette) Writer.Error!void {
    if (cmd.subcommands.len == 0) return;
    try w.print("\n{s}Subcommands:{s}\n", .{ p.section, p.reset });
    for (cmd.subcommands) |sub| {
        try w.print("  {s}{s:<17}{s}{s}{s}{s}\n", .{
            p.cmd, sub.name, p.reset, p.desc, sub.description, p.reset,
        });
    }
    if (parent.len > 0) {
        try w.print("\n{s}Run '{s} {s} {s} <subcommand> --help' for details.{s}\n", .{
            p.desc, app.name, parent, cmd.name, p.reset,
        });
    } else {
        try w.print("\n{s}Run '{s} {s} <subcommand> --help' for details.{s}\n", .{
            p.desc, app.name, cmd.name, p.reset,
        });
    }
}

/// Print the "Arguments:" section.
fn printCmdArguments(w: *Writer, cmd: Command, p: colour.Palette) Writer.Error!void {
    if (cmd.args.len == 0) return;
    try w.print("\n{s}Arguments:{s}\n", .{ p.section, p.reset });
    for (cmd.args) |a| {
        var buf: [128]u8 = undefined;
        const label = fmtArgLabel(a, &buf);
        try w.print("  {s}{s:<28}{s}{s}{s}{s}\n", .{
            p.cmd, label, p.reset, p.desc, a.description, p.reset,
        });
    }
}

/// Print the command-level "Flags:" section.
fn printCmdFlags(w: *Writer, cmd: Command, p: colour.Palette) Writer.Error!void {
    if (cmd.flags.len == 0) return;
    try w.print("\n{s}Flags:{s}\n", .{ p.section, p.reset });
    for (cmd.flags) |f| try printFlagHelp(w, f, p);
}

// ── Single-Flag Formatting ─────────────────────────────────────────────

/// Print one flag row: left column + description + meta annotations.
fn printFlagHelp(w: *Writer, f: FlagDef, p: colour.Palette) Writer.Error!void {
    var left_buf: [128]u8 = undefined;
    const left = fmtFlagLeft(f, &left_buf);

    try w.print("  {s}{s:<28}{s}{s}{s}", .{
        p.flag, left, p.reset, p.flag_desc, f.description,
    });
    try printFlagMeta(w, f, p);
    try w.print("{s}\n", .{p.reset});
}

/// Print the trailing meta annotations (required, default, env, conflicts, negatable).
fn printFlagMeta(w: *Writer, f: FlagDef, p: colour.Palette) Writer.Error!void {
    if (f.required)
        try w.print(" {s}(required){s}", .{ p.required, p.reset });
    if (f.default) |def|
        try w.print(" {s}(default: {s}){s}", .{ p.flag_desc, def, p.reset });
    if (f.env) |env_name|
        try w.print(" {s}[${s}]{s}", .{ p.env, env_name, p.reset });
    if (f.conflicts.len > 0) {
        try w.print(" {s}(conflicts: ", .{p.flag_desc});
        for (f.conflicts, 0..) |c, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("--{s}", .{c});
        }
        try w.print("){s}", .{p.reset});
    }
    if (f.negatable)
        try w.print(" {s}(--no-{s} to disable){s}", .{ p.flag_desc, f.name, p.reset });
}

// ── Label Formatting ───────────────────────────────────────────────────

/// Format an arg label like `<TOPIC>` or `[PAYLOAD]` into `buf`.
///
/// Truncates rather than overflows when `buf` is too small; callers that
/// care about exact width should size `buf` to at least `a.name.len + 2`.
pub fn fmtArgLabel(a: ArgDef, buf: []u8) []const u8 {
    if (buf.len < 2) return buf[0..0];
    var pos: usize = 0;
    buf[pos] = if (a.required) '<' else '[';
    pos += 1;
    for (a.name) |c| {
        if (pos + 1 >= buf.len) break;
        buf[pos] = toUpper(c);
        pos += 1;
    }
    buf[pos] = if (a.required) '>' else ']';
    pos += 1;
    return buf[0..pos];
}

/// Format the left column for a flag: `-p, --port <PORT>` or `    --verbose`.
pub fn fmtFlagLeft(f: FlagDef, buf: []u8) []const u8 {
    var pos: usize = 0;
    pos = writeShortPrefix(f, buf, pos);
    pos = writeLongName(f, buf, pos);
    pos = writeValuePlaceholder(f, buf, pos);
    return buf[0..pos];
}

/// Write `-X, ` or `    ` into buf. Truncates on overflow.
fn writeShortPrefix(f: FlagDef, buf: []u8, start: usize) usize {
    if (start + 4 > buf.len) return start;
    if (f.short) |s| {
        buf[start] = '-';
        buf[start + 1] = s;
        buf[start + 2] = ',';
        buf[start + 3] = ' ';
    } else {
        @memset(buf[start .. start + 4], ' ');
    }
    return start + 4;
}

/// Write `--name` into buf. Truncates on overflow.
fn writeLongName(f: FlagDef, buf: []u8, start: usize) usize {
    var pos = start;
    if (pos + 2 > buf.len) return pos;
    buf[pos] = '-';
    buf[pos + 1] = '-';
    pos += 2;
    for (f.name) |c| {
        if (pos >= buf.len) break;
        buf[pos] = c;
        pos += 1;
    }
    return pos;
}

/// Write ` <VALUE>` into buf if the flag takes a value. Truncates on overflow.
fn writeValuePlaceholder(f: FlagDef, buf: []u8, start: usize) usize {
    if (!f.takes_value) return start;
    var pos = start;
    if (pos + 2 > buf.len) return pos;
    buf[pos] = ' ';
    pos += 1;
    buf[pos] = '<';
    pos += 1;
    if (f.value_name.len > 0) {
        for (f.value_name) |c| {
            if (pos + 1 >= buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
    } else {
        for (f.name) |c| {
            if (pos + 1 >= buf.len) break;
            buf[pos] = if (c == '-') '_' else toUpper(c);
            pos += 1;
        }
    }
    if (pos >= buf.len) return pos;
    buf[pos] = '>';
    return pos + 1;
}

/// Write a name in uppercase to the writer.
fn writeUppercase(w: *Writer, name: []const u8) Writer.Error!void {
    for (name) |c| try w.writeByte(toUpper(c));
}

/// Convert a lowercase ASCII char to uppercase; pass others through.
fn toUpper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "fmtArgLabel required" {
    var buf: [64]u8 = undefined;
    const label = fmtArgLabel(.{ .name = "topic", .required = true }, &buf);
    try std.testing.expectEqualStrings("<TOPIC>", label);
}

test "fmtArgLabel optional" {
    var buf: [64]u8 = undefined;
    const label = fmtArgLabel(.{ .name = "payload", .required = false }, &buf);
    try std.testing.expectEqualStrings("[PAYLOAD]", label);
}

test "fmtArgLabel truncates rather than overflowing" {
    var buf: [4]u8 = undefined;
    const label = fmtArgLabel(.{ .name = "very-long-name", .required = true }, &buf);
    try std.testing.expect(label.len <= 4);
    try std.testing.expectEqual(@as(u8, '<'), label[0]);
    try std.testing.expectEqual(@as(u8, '>'), label[label.len - 1]);
}

test "fmtFlagLeft with short" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "port", .short = 'p', .default = "7890", .description = "Store port" }, &buf);
    try std.testing.expectEqualStrings("-p, --port <PORT>", left);
}

test "fmtFlagLeft long only no value" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "no-persist", .takes_value = false, .description = "Don't persist" }, &buf);
    try std.testing.expectEqualStrings("    --no-persist", left);
}

test "fmtFlagLeft with custom value_name" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "every", .value_name = "INTERVAL", .description = "Interval" }, &buf);
    try std.testing.expectEqualStrings("    --every <INTERVAL>", left);
}

test "fmtFlagLeft long only with value" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "data-dir", .description = "Data directory" }, &buf);
    try std.testing.expectEqualStrings("    --data-dir <DATA_DIR>", left);
}

test "toUpper" {
    try std.testing.expectEqual(@as(u8, 'A'), toUpper('a'));
    try std.testing.expectEqual(@as(u8, 'Z'), toUpper('z'));
    try std.testing.expectEqual(@as(u8, '-'), toUpper('-'));
    try std.testing.expectEqual(@as(u8, '0'), toUpper('0'));
}

test "printRootHelp writes to provided writer" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const app = App{
        .name = "demo",
        .description = "demo app",
        .commands = &.{.{ .name = "status", .description = "show status" }},
    };
    try printRootHelp(std.testing.io, &aw.writer, &app);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Usage:") != null);
}

test "printCommandHelp writes to provided writer" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const app = App{ .name = "demo" };
    const cmd = Command{
        .name = "status",
        .description = "show status",
        .flags = &.{.{ .name = "verbose", .takes_value = false, .description = "v" }},
    };
    try printCommandHelp(std.testing.io, &aw.writer, &app, cmd, "");
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--verbose") != null);
}
