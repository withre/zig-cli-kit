//! Named ANSI colour constants and TTY detection.
//!
//! All escape sequences live here — no other module should contain raw
//! `\x1b[…` literals. Colours are returned as empty strings when the
//! output is not a terminal, giving automatic no-colour fallback.
//!
//! The default palette is deliberately the only palette: there is no
//! theming, no configuration, and no env var beyond the TTY check. It is a
//! two-tone scheme — primary orange for what the user *types* (app title,
//! command names, section headings) and secondary blue for what the user
//! *passes* (flags, environment variables) — with neutral greys for
//! descriptions. Green is off-limits anywhere in the palette; the test at
//! the bottom enforces that so a future colour cannot drift back to it.

const std = @import("std");
const builtin = @import("builtin");

// ── Raw escape sequences (private) ────────────────────────────────────

// Primary: orange. Secondary: blue. Greys stay neutral (never green-
// dominant). `required` is a warm accent that reads as a warning without
// being confused for the orange primary.
const esc_title = "\x1b[38;2;225;140;70m"; // rgb(225,140,70) — orange (primary)
const esc_section = "\x1b[38;2;225;140;70m\x1b[1m"; // rgb(225,140,70) bold — orange (primary)
const esc_cmd = "\x1b[38;2;225;140;70m"; // rgb(225,140,70) — orange (primary)
const esc_desc = "\x1b[38;2;130;135;140m"; // rgb(130,135,140) — neutral grey
const esc_flag = "\x1b[38;2;110;160;220m"; // rgb(110,160,220) — blue (secondary)
const esc_flag_desc = "\x1b[38;2;100;105;110m"; // rgb(100,105,110) — dim neutral grey
const esc_env = "\x1b[38;2;110;160;220m"; // rgb(110,160,220) — blue (secondary)
const esc_required = "\x1b[38;2;180;130;100m"; // rgb(180,130,100) — muted terracotta (warm accent)
const esc_reset = "\x1b[0m"; // reset all attributes

/// A resolved set of colour strings — either real escapes or empty.
pub const Palette = struct {
    title: []const u8,
    section: []const u8,
    cmd: []const u8,
    desc: []const u8,
    flag: []const u8,
    flag_desc: []const u8,
    env: []const u8,
    required: []const u8,
    reset: []const u8,
};

/// Palette with all escapes enabled.
const palette_colour = Palette{
    .title = esc_title,
    .section = esc_section,
    .cmd = esc_cmd,
    .desc = esc_desc,
    .flag = esc_flag,
    .flag_desc = esc_flag_desc,
    .env = esc_env,
    .required = esc_required,
    .reset = esc_reset,
};

/// Palette with every field set to "".
const palette_plain = Palette{
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

/// Detect whether stderr is a TTY using Zig's IO abstraction.
///
/// This avoids a libc dependency and lets embedders provide their own IO
/// implementation in tests or non-standard runtimes.
pub fn isTty(io: std.Io) bool {
    return std.Io.File.stderr().isTty(io) catch false;
}

/// Return the appropriate palette for the current output.
pub fn detect(io: std.Io) Palette {
    return if (isTty(io)) palette_colour else palette_plain;
}

/// Width used when the terminal cannot be measured (not a tty, unsupported
/// platform, or the query fails). 80 is the conventional minimum a help
/// screen should read well at.
pub const default_width: usize = 80;

/// Column count of the terminal behind stdout, or `default_width`.
///
/// Goes through `io.operate(.device_io_control)` -- the same route
/// `std.Progress` uses -- rather than calling ioctl directly, so embedders
/// providing their own `std.Io` keep control of the query. Windows has a
/// different console API and WASI has no terminal; both take the default.
pub fn terminalWidth(io: std.Io) usize {
    const file = std.Io.File.stdout();
    const tty = file.isTty(io) catch return default_width;
    if (!tty) return default_width;

    switch (builtin.os.tag) {
        .windows, .wasi => return default_width,
        else => {
            var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            const result = io.operate(.{ .device_io_control = .{
                .file = file,
                .code = std.posix.T.IOCGWINSZ,
                .arg = &ws,
            } }) catch return default_width;
            if (result.device_io_control < 0 or ws.col == 0) return default_width;
            return ws.col;
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "plain palette has empty strings" {
    const p = palette_plain;
    try std.testing.expectEqual(@as(usize, 0), p.title.len);
    try std.testing.expectEqual(@as(usize, 0), p.reset.len);
    try std.testing.expectEqual(@as(usize, 0), p.section.len);
}

test "colour palette has non-empty strings" {
    const p = palette_colour;
    try std.testing.expect(p.title.len > 0);
    try std.testing.expect(p.reset.len > 0);
    try std.testing.expect(p.section.len > 0);
}

const Rgb = struct { r: u8, g: u8, b: u8 };

/// Extract the truecolour foreground `38;2;R;G;B` triple from an escape
/// sequence, or null when the sequence carries no truecolour foreground
/// (e.g. `\x1b[0m` reset, `\x1b[1m` bold).
fn truecolourOf(esc: []const u8) ?Rgb {
    const marker = "38;2;";
    const start = (std.mem.indexOf(u8, esc, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, esc, start, 'm') orelse return null;
    var it = std.mem.splitScalar(u8, esc[start..end], ';');
    const r = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const g = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const b = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

fn isGreenDominant(c: Rgb) bool {
    return c.g > c.r and c.g > c.b;
}

test "truecolourOf parses and rejects" {
    const c = truecolourOf("\x1b[38;2;150;165;100m\x1b[1m").?;
    try std.testing.expectEqual(Rgb{ .r = 150, .g = 165, .b = 100 }, c);
    try std.testing.expect(truecolourOf("\x1b[0m") == null);
    try std.testing.expect(truecolourOf("\x1b[1m") == null);
    try std.testing.expect(truecolourOf("") == null);
}

test "isGreenDominant catches the retired greens and passes the palette hues" {
    try std.testing.expect(isGreenDominant(.{ .r = 150, .g = 165, .b = 100 })); // old sage section
    try std.testing.expect(isGreenDominant(.{ .r = 90, .g = 100, .b = 90 })); // old olive env
    try std.testing.expect(!isGreenDominant(.{ .r = 225, .g = 140, .b = 70 })); // orange
    try std.testing.expect(!isGreenDominant(.{ .r = 110, .g = 160, .b = 220 })); // blue
    try std.testing.expect(!isGreenDominant(.{ .r = 130, .g = 135, .b = 140 })); // grey
}

// Iterates every Palette field via type info rather than a hand-written
// list, so a colour added later is checked without anyone remembering to
// extend this test.
test "no palette escape is green-dominant" {
    const p = palette_colour;
    // `Type.Struct` exposes `field_names` (parallel to `field_types` /
    // `field_attrs`) rather than a single `fields` slice.
    inline for (@typeInfo(Palette).@"struct".field_names) |field_name| {
        const esc: []const u8 = @field(p, field_name);
        if (truecolourOf(esc)) |c| {
            if (isGreenDominant(c)) {
                std.debug.print("palette.{s} is green-dominant: rgb({d},{d},{d})\n", .{ field_name, c.r, c.g, c.b });
                return error.GreenInPalette;
            }
        }
    }
}

test "primary is orange, secondary is blue" {
    const p = palette_colour;
    // Primary (title / section / cmd): red-led, blue-poor.
    inline for (.{ p.title, p.section, p.cmd }) |esc| {
        const c = truecolourOf(esc).?;
        try std.testing.expect(c.r > c.g and c.g > c.b);
    }
    // Secondary (flag / env): blue-led.
    inline for (.{ p.flag, p.env }) |esc| {
        const c = truecolourOf(esc).?;
        try std.testing.expect(c.b > c.g and c.b > c.r);
    }
}
