//! Help output formatting: root help, per-command help, flag/arg
//! label rendering. Uses `colour.Palette` — never raw escape codes.
//!
//! All output is written through a caller-supplied `*std.Io.Writer`; this
//! module never touches `std.debug.print` or process stdio directly.
//!
//! Every tabular block (commands, subcommands, flags, arguments, custom
//! sections) goes through one renderer, `Table`, which lays rows out as
//!
//!     name | positional args | description
//!
//! with column widths computed from the longest entry in that block and
//! descriptions word-wrapped to the terminal width, continuation lines
//! indented to the description column. Fixed-width columns were the
//! previous design and produced a wall of text at a dozen commands.

const std = @import("std");
const types = @import("types.zig");
const colour = @import("colour.zig");

const App = types.App;
const Command = types.Command;
const FlagDef = types.FlagDef;
const ArgDef = types.ArgDef;
const HelpSection = types.HelpSection;
const HelpEntry = types.HelpEntry;

const Writer = std.Io.Writer;
const Palette = colour.Palette;

// ── Public entry points ────────────────────────────────────────────────

/// Print the top-level usage / section listing for the whole app, sized
/// and coloured for the terminal behind `io`.
pub fn printRootHelp(io: std.Io, w: *Writer, app: *const App) Writer.Error!void {
    try renderRootHelp(w, app, colour.detect(io), colour.terminalWidth(io));
}

/// Print full help for a single command, sized and coloured for the
/// terminal behind `io`.
pub fn printCommandHelp(
    io: std.Io,
    w: *Writer,
    app: *const App,
    cmd: Command,
    parent_name: []const u8,
) Writer.Error!void {
    try renderCommandHelp(w, app, cmd, parent_name, colour.detect(io), colour.terminalWidth(io));
}

// ── Root Help ──────────────────────────────────────────────────────────

/// Root help with an explicit palette and width. This is the layer tests
/// pin: output depends only on the arguments, never on the environment.
pub fn renderRootHelp(w: *Writer, app: *const App, p: Palette, width: usize) Writer.Error!void {
    try w.print("{s}{s}{s} — {s}{s}{s}\n\n", .{
        p.title, app.name, p.reset, p.desc, app.description, p.reset,
    });
    try w.print("Usage: {s} [global options] <command> [options]\n", .{app.name});

    try printFlagTable(w, "Global Flags", app.global_flags, p, width);

    if (app.help_sections.len == 0) {
        try printCommandTable(w, "Commands", app.commands, p, width);
    } else {
        for (app.help_sections) |sec| try printHelpSection(w, app, sec, p, width);
    }

    try w.print("\n{s}Run '{s} <command> --help' for more information.{s}\n", .{
        p.desc, app.name, p.reset,
    });
}

/// One custom section: command rows (resolved by name from `app.commands`)
/// followed by free-form entry rows, all sharing one set of column widths.
fn printHelpSection(w: *Writer, app: *const App, sec: HelpSection, p: Palette, width: usize) Writer.Error!void {
    var table = Table.init(width);
    for (sec.commands) |name| {
        if (findCommand(app.commands, name)) |cmd| table.measure(cmd.name, argsWidth(cmd.args));
    }
    for (sec.entries) |entry| table.measure(entry.label, 0);
    if (table.rows == 0) return;

    try w.print("\n{s}{s}:{s}\n", .{ p.section, sec.title, p.reset });
    for (sec.commands) |name| {
        if (findCommand(app.commands, name)) |cmd| try table.commandRow(w, cmd, p);
    }
    for (sec.entries) |entry| try table.entryRow(w, entry, p);
}

fn findCommand(commands: []const Command, name: []const u8) ?Command {
    for (commands) |cmd| if (cmd.matches(name)) return cmd;
    return null;
}

// ── Command Help ───────────────────────────────────────────────────────

/// Command help with an explicit palette and width (see `renderRootHelp`).
pub fn renderCommandHelp(
    w: *Writer,
    app: *const App,
    cmd: Command,
    parent_name: []const u8,
    p: Palette,
    width: usize,
) Writer.Error!void {
    try printCmdDescription(w, cmd, parent_name, p);
    try printCmdUsage(w, app, cmd, parent_name, p);
    try printCmdAliases(w, cmd, p);

    if (cmd.subcommands.len > 0) {
        try printCommandTable(w, "Subcommands", cmd.subcommands, p, width);
        try printSubcommandHint(w, app, cmd, parent_name, p);
        return;
    }

    try printArgTable(w, cmd.args, p, width);
    try printFlagTable(w, "Flags", cmd.flags, p, width);
    try printFlagTable(w, "Global Flags", app.global_flags, p, width);
}

/// Print the one-line command description.
fn printCmdDescription(w: *Writer, cmd: Command, parent: []const u8, p: Palette) Writer.Error!void {
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
fn printCmdUsage(w: *Writer, app: *const App, cmd: Command, parent: []const u8, p: Palette) Writer.Error!void {
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
fn printUsageLeaf(w: *Writer, app: *const App, cmd: Command, parent: []const u8, p: Palette) Writer.Error!void {
    if (parent.len > 0) {
        try w.print("  {s} {s} {s}", .{ app.name, parent, cmd.name });
    } else {
        try w.print("  {s} {s}", .{ app.name, cmd.name });
    }
    if (cmd.flags.len > 0 or app.global_flags.len > 0)
        try w.writeAll(" [OPTIONS]");

    for (cmd.args) |a| {
        try w.writeByte(' ');
        try writeArgToken(w, a, p);
    }

    if (cmd.takes_rest) try w.writeAll(" [-- ARGS...]");
    try w.writeAll("\n");
}

/// Print aliases line.
fn printCmdAliases(w: *Writer, cmd: Command, p: Palette) Writer.Error!void {
    if (cmd.aliases.len == 0) return;
    try w.print("\n{s}Aliases:{s} ", .{ p.section, p.reset });
    for (cmd.aliases, 0..) |alias, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}{s}{s}", .{ p.cmd, alias, p.reset });
    }
    try w.writeAll("\n");
}

/// The "Run … --help" hint under a subcommand listing.
fn printSubcommandHint(w: *Writer, app: *const App, cmd: Command, parent: []const u8, p: Palette) Writer.Error!void {
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

// ── Tables ─────────────────────────────────────────────────────────────

/// `Commands:` / `Subcommands:` — name | args | description.
fn printCommandTable(w: *Writer, title: []const u8, commands: []const Command, p: Palette, width: usize) Writer.Error!void {
    if (commands.len == 0) return;
    var table = Table.init(width);
    for (commands) |cmd| table.measure(cmd.name, argsWidth(cmd.args));

    try w.print("\n{s}{s}:{s}\n", .{ p.section, title, p.reset });
    for (commands) |cmd| try table.commandRow(w, cmd, p);
}

/// `Flags:` / `Global Flags:` — `-x, --name <VALUE>` | description + meta.
fn printFlagTable(w: *Writer, title: []const u8, flags: []const FlagDef, p: Palette, width: usize) Writer.Error!void {
    if (flags.len == 0) return;
    var table = Table.init(width);
    for (flags) |f| {
        var buf: [128]u8 = undefined;
        table.measure(fmtFlagLeft(f, &buf), 0);
    }

    try w.print("\n{s}{s}:{s}\n", .{ p.section, title, p.reset });
    for (flags) |f| try table.flagRow(w, f, p);
}

/// `Arguments:` — `<NAME>` | description.
fn printArgTable(w: *Writer, args: []const ArgDef, p: Palette, width: usize) Writer.Error!void {
    if (args.len == 0) return;
    var table = Table.init(width);
    for (args) |a| table.measure("", argLabelWidth(a));
    // Arg labels sit in the first column; the measure above sized them as
    // the args column so `<NAME>` widths are counted, then we fold that
    // into the name column and drop the (empty) args column.
    table.name_w = table.args_w;
    table.args_w = 0;

    try w.print("\n{s}Arguments:{s}\n", .{ p.section, p.reset });
    for (args) |a| {
        var buf: [128]u8 = undefined;
        const label = fmtArgLabel(a, &buf);
        try table.beginRow(w, p.cmd, label, p);
        try table.description(w, &.{Segment.prose(a.description, p.desc)}, p);
    }
}

/// Column geometry for one block of rows, plus the row writers that use
/// it. Widths are measured in visible characters; colour escapes are
/// written around cells and never counted.
const Table = struct {
    /// Left margin before the name column.
    const indent: usize = 2;
    /// Gap between columns.
    const gap: usize = 2;
    /// Descriptions always get at least this much room, even on absurdly
    /// narrow terminals; below it, wrapping produces more noise than help.
    const min_desc_w: usize = 20;

    name_w: usize = 0,
    /// Zero means no row has positional args and the column is omitted.
    args_w: usize = 0,
    width: usize,
    rows: usize = 0,

    fn init(width: usize) Table {
        return .{ .width = width };
    }

    /// Record one row's cell widths during the measuring pass.
    fn measure(t: *Table, name: []const u8, args_width: usize) void {
        t.name_w = @max(t.name_w, name.len);
        t.args_w = @max(t.args_w, args_width);
        t.rows += 1;
    }

    /// Column at which descriptions start.
    fn descCol(t: Table) usize {
        const args_part: usize = if (t.args_w > 0) t.args_w + gap else 0;
        return indent + t.name_w + gap + args_part;
    }

    /// Right edge for wrapping: the terminal width, widened if needed so
    /// the description column keeps `min_desc_w` characters.
    fn wrapWidth(t: Table) usize {
        return @max(t.width, t.descCol() + min_desc_w);
    }

    /// Write the name cell (coloured, padded to the column).
    fn beginRow(t: Table, w: *Writer, name_colour: []const u8, name: []const u8, p: Palette) Writer.Error!void {
        try w.splatByteAll(' ', indent);
        try w.print("{s}{s}{s}", .{ name_colour, name, p.reset });
        try w.splatByteAll(' ', (t.name_w - name.len) + gap);
    }

    /// Write the args cell for a command row (blue), padded to the column.
    fn argsCell(t: Table, w: *Writer, args: []const ArgDef, p: Palette) Writer.Error!void {
        if (t.args_w == 0) return;
        for (args, 0..) |a, i| {
            if (i > 0) try w.writeByte(' ');
            try writeArgToken(w, a, p);
        }
        try w.splatByteAll(' ', (t.args_w - argsWidth(args)) + gap);
    }

    fn commandRow(t: Table, w: *Writer, cmd: Command, p: Palette) Writer.Error!void {
        try t.beginRow(w, p.cmd, cmd.name, p);
        try t.argsCell(w, cmd.args, p);
        try t.description(w, &.{Segment.prose(cmd.description, p.desc)}, p);
    }

    fn entryRow(t: Table, w: *Writer, entry: HelpEntry, p: Palette) Writer.Error!void {
        try t.beginRow(w, p.cmd, entry.label, p);
        try t.argsCell(w, &.{}, p);
        try t.description(w, &.{Segment.prose(entry.description, p.desc)}, p);
    }

    fn flagRow(t: Table, w: *Writer, f: FlagDef, p: Palette) Writer.Error!void {
        var left_buf: [128]u8 = undefined;
        const left = fmtFlagLeft(f, &left_buf);
        try t.beginRow(w, p.flag, left, p);

        // Meta annotations are atomic so `(default: x)` never splits
        // across lines. Conflicts are one token per name so a long list
        // can still wrap between names.
        var segs: [8 + 16]Segment = undefined;
        var n: usize = 0;
        segs[n] = Segment.prose(f.description, p.flag_desc);
        n += 1;
        if (f.required) {
            segs[n] = Segment.token("(required)", "", "", p.required);
            n += 1;
        }
        if (f.default) |def| {
            segs[n] = Segment.token("(default: ", def, ")", p.flag_desc);
            n += 1;
        }
        if (f.env) |env_name| {
            segs[n] = Segment.token("[$", env_name, "]", p.env);
            n += 1;
        }
        if (f.conflicts.len > 0) {
            segs[n] = Segment.token("(conflicts:", "", "", p.flag_desc);
            n += 1;
            for (f.conflicts, 0..) |c, i| {
                if (n >= segs.len - 1) break;
                const last = i + 1 == f.conflicts.len;
                segs[n] = Segment.token("--", c, if (last) ")" else ",", p.flag_desc);
                n += 1;
            }
        }
        if (f.negatable) {
            segs[n] = Segment.token("(--no-", f.name, " to disable)", p.flag_desc);
            n += 1;
        }
        try t.description(w, segs[0..n], p);
    }

    /// Word-wrap `segs` into the description column, starting at the
    /// current cursor (already at `descCol`), and end the row.
    fn description(t: Table, w: *Writer, segs: []const Segment, p: Palette) Writer.Error!void {
        var cur: Cursor = .{ .start = t.descCol(), .limit = t.wrapWidth() };
        cur.col = cur.start;

        // One SGR pair per segment, not per word: open before the first
        // token, close after the last, and re-open only when a line break
        // interrupts the run. Per-word pairs tripled the byte count of a
        // coloured screen for no visible difference.
        for (segs) |seg| {
            try w.writeAll(seg.colour);
            if (seg.atomic) {
                try cur.place(w, seg.parts(), seg.width(), seg.colour, p);
            } else {
                var words = std.mem.tokenizeScalar(u8, seg.a, ' ');
                while (words.next()) |word| {
                    try cur.place(w, .{ word, "", "" }, word.len, seg.colour, p);
                }
            }
            try w.writeAll(p.reset);
        }
        try w.writeAll("\n");
    }

    /// Wrapping state for one description cell.
    const Cursor = struct {
        start: usize,
        limit: usize,
        col: usize = 0,
        line_has_text: bool = false,

        /// Emit one unbreakable token, moving to a continuation line first
        /// if it would cross `limit`. A token wider than the whole column is
        /// written anyway rather than dropped. The active colour is closed
        /// before the break and re-opened after the indent so padding is
        /// never inside an escape.
        fn place(
            c: *Cursor,
            w: *Writer,
            parts: [3][]const u8,
            token_w: usize,
            token_colour: []const u8,
            p: Palette,
        ) Writer.Error!void {
            if (c.line_has_text and c.col + 1 + token_w > c.limit) {
                try w.writeAll(p.reset);
                try w.writeAll("\n");
                try w.splatByteAll(' ', c.start);
                try w.writeAll(token_colour);
                c.col = c.start;
                c.line_has_text = false;
            }
            if (c.line_has_text) {
                try w.writeByte(' ');
                c.col += 1;
            }
            for (parts) |part| try w.writeAll(part);
            c.col += token_w;
            c.line_has_text = true;
        }
    };
};

/// A run of description text with one colour. `atomic` runs are placed
/// as a single token; prose runs break at spaces.
///
/// Parts are held by value (not as a slice) so a Segment can be stored in
/// a caller's array without pointing at a temporary. Three parts cover
/// every annotation we emit (`(default: `, value, `)`).
const Segment = struct {
    a: []const u8,
    b: []const u8 = "",
    c: []const u8 = "",
    colour: []const u8,
    atomic: bool,

    fn prose(text: []const u8, colour_: []const u8) Segment {
        return .{ .a = text, .colour = colour_, .atomic = false };
    }

    fn token(a: []const u8, b: []const u8, c: []const u8, colour_: []const u8) Segment {
        return .{ .a = a, .b = b, .c = c, .colour = colour_, .atomic = true };
    }

    fn parts(s: Segment) [3][]const u8 {
        return .{ s.a, s.b, s.c };
    }

    fn width(s: Segment) usize {
        return s.a.len + s.b.len + s.c.len;
    }
};

// ── Positional-arg tokens ──────────────────────────────────────────────

/// Visible width of `<NAME>` / `[NAME]` for one arg.
fn argLabelWidth(a: ArgDef) usize {
    return a.name.len + 2;
}

/// Visible width of a command's args cell: tokens joined by one space.
fn argsWidth(args: []const ArgDef) usize {
    if (args.len == 0) return 0;
    var n: usize = args.len - 1;
    for (args) |a| n += argLabelWidth(a);
    return n;
}

/// Write one positional arg as usage shows it: `<FILE>` when required,
/// `[FILE]` when optional. A trailing `...` in the name (e.g. `file...`)
/// passes through, so variadic reads `<FILE...>`. Coloured as an argument
/// (secondary), not as a command.
fn writeArgToken(w: *Writer, a: ArgDef, p: Palette) Writer.Error!void {
    try w.writeAll(p.flag);
    try w.writeByte(if (a.required) '<' else '[');
    try writeUppercase(w, a.name);
    try w.writeByte(if (a.required) '>' else ']');
    try w.writeAll(p.reset);
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

const testing = std.testing;

/// Palette with every field "" — what non-tty output gets. Tests render
/// with it so goldens are byte-exact and free of escapes.
const plain: Palette = .{
    .title = "",
    .section = "",
    .cmd = "",
    .desc = "",
    .flag = "",
    .flag_desc = "",
    .env = "",
    .required = "",
    .reset = "",
};

test "fmtArgLabel required" {
    var buf: [64]u8 = undefined;
    const label = fmtArgLabel(.{ .name = "topic", .required = true }, &buf);
    try testing.expectEqualStrings("<TOPIC>", label);
}

test "fmtArgLabel optional" {
    var buf: [64]u8 = undefined;
    const label = fmtArgLabel(.{ .name = "payload", .required = false }, &buf);
    try testing.expectEqualStrings("[PAYLOAD]", label);
}

test "fmtArgLabel truncates rather than overflowing" {
    var buf: [4]u8 = undefined;
    const label = fmtArgLabel(.{ .name = "very-long-name", .required = true }, &buf);
    try testing.expect(label.len <= 4);
    try testing.expectEqual(@as(u8, '<'), label[0]);
    try testing.expectEqual(@as(u8, '>'), label[label.len - 1]);
}

test "fmtFlagLeft with short" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "port", .short = 'p', .default = "7890", .description = "Store port" }, &buf);
    try testing.expectEqualStrings("-p, --port <PORT>", left);
}

test "fmtFlagLeft long only no value" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "no-persist", .takes_value = false, .description = "Don't persist" }, &buf);
    try testing.expectEqualStrings("    --no-persist", left);
}

test "fmtFlagLeft with custom value_name" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "every", .value_name = "INTERVAL", .description = "Interval" }, &buf);
    try testing.expectEqualStrings("    --every <INTERVAL>", left);
}

test "fmtFlagLeft long only with value" {
    var buf: [64]u8 = undefined;
    const left = fmtFlagLeft(.{ .name = "data-dir", .description = "Data directory" }, &buf);
    try testing.expectEqualStrings("    --data-dir <DATA_DIR>", left);
}

test "toUpper" {
    try testing.expectEqual(@as(u8, 'A'), toUpper('a'));
    try testing.expectEqual(@as(u8, 'Z'), toUpper('z'));
    try testing.expectEqual(@as(u8, '-'), toUpper('-'));
    try testing.expectEqual(@as(u8, '0'), toUpper('0'));
}

test "printRootHelp writes to provided writer" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const app = App{
        .name = "demo",
        .description = "demo app",
        .commands = &.{.{ .name = "status", .description = "show status" }},
    };
    try printRootHelp(testing.io, &aw.writer, &app);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "demo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Usage:") != null);
}

test "printCommandHelp writes to provided writer" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const app = App{ .name = "demo" };
    const cmd = Command{
        .name = "status",
        .description = "show status",
        .flags = &.{.{ .name = "verbose", .takes_value = false, .description = "v" }},
    };
    try printCommandHelp(testing.io, &aw.writer, &app, cmd, "");
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "status") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--verbose") != null);
}

// A twelve-command app in the shape of `ref`: one or two positionals per
// command, some variadic (`file...`), descriptions of varying length.
const files_arg: ArgDef = .{ .name = "file...", .required = true, .description = "Host files or directories" };
const file_arg: ArgDef = .{ .name = "file", .required = true, .description = "Host file" };
const source_arg: ArgDef = .{ .name = "source", .required = true, .description = "Source spec" };

const twelve: App = .{
    .name = "ref",
    .description = "keep marked regions in sync with their sources",
    .global_flags = &.{
        .{ .name = "verbose", .short = 'v', .takes_value = false, .description = "Print each step" },
        .{ .name = "config", .short = 'c', .env = "REF_CONFIG", .default = "ref.toml", .description = "Config file to read" },
    },
    .commands = &.{
        .{ .name = "add", .args = &.{ file_arg, source_arg }, .description = "Insert a new ref: marker, then sync it" },
        .{ .name = "sync", .args = &.{files_arg}, .description = "Resolve sources and update marked regions in place" },
        .{ .name = "check", .args = &.{files_arg}, .description = "Read-only drift check; non-zero exit on drift" },
        .{ .name = "preview", .args = &.{files_arg}, .description = "Show what sync would change; write nothing" },
        .{ .name = "status", .args = &.{files_arg}, .description = "List refs and whether each is in-sync or drifted" },
        .{ .name = "update", .args = &.{files_arg}, .description = "Advance floating pins to newer source versions" },
        .{ .name = "clean", .args = &.{files_arg}, .description = "Empty marked regions but keep the markers" },
        .{ .name = "list", .args = &.{files_arg}, .description = "Inventory refs and anchors; resolves nothing" },
        .{ .name = "fmt", .args = &.{files_arg}, .description = "Canonicalise marker formatting (--check gates)" },
        .{ .name = "pin", .args = &.{files_arg}, .description = "Set a ref's desired version (--to / --unpin)" },
        .{ .name = "inspect", .args = &.{file_arg}, .description = "Dump parsed refs and diagnostics" },
        .{ .name = "doctor", .args = &.{file_arg}, .description = "Report stale residue, missing fences, orphans" },
    },
};

test "golden: twelve-command root help at 100 columns" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try renderRootHelp(&aw.writer, &twelve, plain, 100);

    const want =
        \\ref — keep marked regions in sync with their sources
        \\
        \\Usage: ref [global options] <command> [options]
        \\
        \\Global Flags:
        \\  -v, --verbose          Print each step
        \\  -c, --config <CONFIG>  Config file to read (default: ref.toml) [$REF_CONFIG]
        \\
        \\Commands:
        \\  add      <FILE> <SOURCE>  Insert a new ref: marker, then sync it
        \\  sync     <FILE...>        Resolve sources and update marked regions in place
        \\  check    <FILE...>        Read-only drift check; non-zero exit on drift
        \\  preview  <FILE...>        Show what sync would change; write nothing
        \\  status   <FILE...>        List refs and whether each is in-sync or drifted
        \\  update   <FILE...>        Advance floating pins to newer source versions
        \\  clean    <FILE...>        Empty marked regions but keep the markers
        \\  list     <FILE...>        Inventory refs and anchors; resolves nothing
        \\  fmt      <FILE...>        Canonicalise marker formatting (--check gates)
        \\  pin      <FILE...>        Set a ref's desired version (--to / --unpin)
        \\  inspect  <FILE>           Dump parsed refs and diagnostics
        \\  doctor   <FILE>           Report stale residue, missing fences, orphans
        \\
        \\Run 'ref <command> --help' for more information.
        \\
    ;
    try testing.expectEqualStrings(want, aw.writer.buffered());
}

test "golden: help_sections resolve command rows from ArgDefs, entries stay free-form" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var app = twelve;
    app.global_flags = &.{};
    app.help_sections = &.{
        .{ .title = "Write", .commands = &.{ "add", "sync" } },
        .{
            .title = "Markers",
            .entries = &.{
                .{ .label = "# ref: <source>", .description = "the one line you write by hand" },
                .{ .label = "# ref:end", .description = "the fence ref writes and owns" },
            },
        },
    };
    try renderRootHelp(&aw.writer, &app, plain, 100);

    const want =
        \\ref — keep marked regions in sync with their sources
        \\
        \\Usage: ref [global options] <command> [options]
        \\
        \\Write:
        \\  add   <FILE> <SOURCE>  Insert a new ref: marker, then sync it
        \\  sync  <FILE...>        Resolve sources and update marked regions in place
        \\
        \\Markers:
        \\  # ref: <source>  the one line you write by hand
        \\  # ref:end        the fence ref writes and owns
        \\
        \\Run 'ref <command> --help' for more information.
        \\
    ;
    try testing.expectEqualStrings(want, aw.writer.buffered());
}

test "narrow width wraps descriptions and indents continuations to the description column" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const width: usize = 50;
    try renderRootHelp(&aw.writer, &twelve, plain, width);
    const out = aw.writer.buffered();

    // Every table row fits, and the wrapped row for `sync` continues under
    // its description column (2 + 7 + 2 + 15 + 2 = 28 spaces). Only rows
    // are checked: the title line is not tabular and is never wrapped.
    // `**` array repetition is gone from the language on this nightly;
    // `@splat` into a sized array is the replacement.
    const cont_indent: [28]u8 = @splat(' ');
    var lines = std.mem.splitScalar(u8, out, '\n');
    var rows: usize = 0;
    var saw_continuation = false;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ")) continue;
        rows += 1;
        try testing.expect(line.len <= width);
        if (std.mem.startsWith(u8, line, &cont_indent) and line.len > 28 and line[28] != ' ') saw_continuation = true;
    }
    try testing.expect(rows > 14); // 2 flags + 12 commands, plus continuations
    try testing.expect(saw_continuation);

    const want_sync =
        \\  sync     <FILE...>        Resolve sources and
        \\                            update marked regions
        \\                            in place
        \\
    ;
    try testing.expect(std.mem.indexOf(u8, out, want_sync) != null);
}

test "flag meta annotations never split and wrap as whole tokens" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const app: App = .{
        .name = "t",
        .global_flags = &.{
            .{ .name = "config", .short = 'c', .env = "REF_CONFIG", .default = "ref.toml", .required = true, .description = "Config file to read" },
        },
    };
    // Description column is 25; at 60 wide, `(default: ref.toml)` (19)
    // does not fit after `(required)` and moves whole to the next line.
    try renderRootHelp(&aw.writer, &app, plain, 60);
    const out = aw.writer.buffered();

    const want =
        \\  -c, --config <CONFIG>  Config file to read (required)
        \\                         (default: ref.toml) [$REF_CONFIG]
        \\
    ;
    const from = std.mem.indexOf(u8, out, "  -c,").?;
    try testing.expectEqualStrings(want, out[from .. from + want.len]);
}

test "args column is omitted when no command in the block has args" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const app: App = .{
        .name = "t",
        .commands = &.{
            .{ .name = "up", .description = "start" },
            .{ .name = "status", .description = "report" },
        },
    };
    try renderRootHelp(&aw.writer, &app, plain, 80);
    const want =
        \\Commands:
        \\  up      start
        \\  status  report
        \\
    ;
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), want) != null);
}

test "command help: subcommand and flag tables use computed widths" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const app: App = .{ .name = "t", .global_flags = &.{
        .{ .name = "verbose", .short = 'v', .takes_value = false, .description = "Print each step" },
    } };
    const leaf: Command = .{
        .name = "pin",
        .description = "Set a ref's desired version",
        .args = &.{files_arg},
        .flags = &.{
            .{ .name = "to", .description = "Version to pin to", .conflicts = &.{"unpin"} },
            .{ .name = "unpin", .takes_value = false, .description = "Remove the pin", .conflicts = &.{"to"} },
        },
    };
    try renderCommandHelp(&aw.writer, &app, leaf, "", plain, 100);

    const want =
        \\pin — Set a ref's desired version
        \\
        \\Usage:
        \\  t pin [OPTIONS] <FILE...>
        \\
        \\Arguments:
        \\  <FILE...>  Host files or directories
        \\
        \\Flags:
        \\      --to <TO>  Version to pin to (conflicts: --unpin)
        \\      --unpin    Remove the pin (conflicts: --to)
        \\
        \\Global Flags:
        \\  -v, --verbose  Print each step
        \\
    ;
    try testing.expectEqualStrings(want, aw.writer.buffered());
}

test "colours land on name, args, and description separately" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const p: Palette = .{
        .title = "<T>",
        .section = "<S>",
        .cmd = "<C>",
        .desc = "<D>",
        .flag = "<F>",
        .flag_desc = "<FD>",
        .env = "<E>",
        .required = "<R>",
        .reset = "</>",
    };
    const app: App = .{
        .name = "t",
        .commands = &.{.{ .name = "add", .args = &.{file_arg}, .description = "insert one" }},
    };
    try renderRootHelp(&aw.writer, &app, p, 80);
    const out = aw.writer.buffered();
    // Name in primary, args in secondary, description in grey -- one
    // escape pair per cell; padding is outside the escapes so widths stay
    // exact.
    try testing.expect(std.mem.indexOf(u8, out, "  <C>add</>  <F><FILE></>  <D>insert one</>\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<S>Commands:</>") != null);
}

test "a wrapped cell opens its colour once per line, not once per word" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const p: Palette = .{
        .title = "",
        .section = "",
        .cmd = "<C>",
        .desc = "<D>",
        .flag = "",
        .flag_desc = "",
        .env = "",
        .required = "",
        .reset = "</>",
    };
    const app: App = .{
        .name = "t",
        .commands = &.{.{ .name = "sync", .description = "Resolve sources and update marked regions in place" }},
    };
    try renderRootHelp(&aw.writer, &app, p, 40);
    const out = aw.writer.buffered();

    // Description column is 8; 32 chars of room: two lines, so exactly two
    // opens and two closes for eight words. The break sits outside the
    // escapes so the continuation indent is plain spaces.
    const want =
        \\  <C>sync</>  <D>Resolve sources and update</>
        \\        <D>marked regions in place</>
        \\
    ;
    const from = std.mem.indexOf(u8, out, "  <C>sync").?;
    try testing.expectEqualStrings(want, out[from .. from + want.len]);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out[from .. from + want.len], "<D>"));
}
