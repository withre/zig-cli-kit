//! Small predicates that classify raw argv tokens. No state, no I/O.

const std = @import("std");

/// True for `help`, `--help`, or `-h`.
pub fn isHelpToken(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "help") or
        std.mem.eql(u8, tok, "--help") or
        std.mem.eql(u8, tok, "-h");
}

test isHelpToken {
    try std.testing.expect(isHelpToken("help"));
    try std.testing.expect(isHelpToken("--help"));
    try std.testing.expect(isHelpToken("-h"));
    try std.testing.expect(!isHelpToken("status"));
    try std.testing.expect(!isHelpToken(""));
}

/// True for `version` or `--version`.
pub fn isVersionToken(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "version") or
        std.mem.eql(u8, tok, "--version");
}

test isVersionToken {
    try std.testing.expect(isVersionToken("version"));
    try std.testing.expect(isVersionToken("--version"));
    try std.testing.expect(!isVersionToken("help"));
    try std.testing.expect(!isVersionToken("-v"));
}

/// True for help flags that parsers skip before the help shortcut runs.
pub fn isHelpFlag(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "--help") or std.mem.eql(u8, tok, "-h");
}

/// True when `--help` or `-h` appears before the `--` separator.
pub fn helpRequestedIn(args: []const []const u8) bool {
    for (args) |a| {
        if (isOptionsTerminator(a)) return false;
        if (isHelpFlag(a)) return true;
    }
    return false;
}

test helpRequestedIn {
    try std.testing.expect(helpRequestedIn(&.{ "foo", "--help" }));
    try std.testing.expect(helpRequestedIn(&.{"-h"}));
    try std.testing.expect(!helpRequestedIn(&.{ "foo", "bar" }));
    try std.testing.expect(!helpRequestedIn(&.{ "--", "--help" }));
    try std.testing.expect(!helpRequestedIn(&.{}));
}

/// True if `tok` looks like a long flag: starts with `--` and has at
/// least one char after.
pub fn isLongFlag(tok: []const u8) bool {
    return tok.len > 2 and tok[0] == '-' and tok[1] == '-';
}

test isLongFlag {
    try std.testing.expect(isLongFlag("--foo"));
    try std.testing.expect(!isLongFlag("--")); // bare separator
    try std.testing.expect(!isLongFlag("-f"));
    try std.testing.expect(!isLongFlag("foo"));
}

/// True if `tok` looks like a short flag cluster: `-X` or `-Xvalue`.
pub fn isShortFlag(tok: []const u8) bool {
    return tok.len >= 2 and tok[0] == '-' and tok[1] != '-';
}

/// True for any token starting with `-`, including `--` and bare `-`.
pub fn isFlagShaped(tok: []const u8) bool {
    return tok.len > 0 and tok[0] == '-';
}

pub const LongFlag = struct { name: []const u8, value: ?[]const u8 };

/// Split a `--long` token into its name and optional `=value` payload.
pub fn splitLongFlag(tok: []const u8) ?LongFlag {
    std.debug.assert(isLongFlag(tok));
    const body = tok[2..];
    if (body.len == 0 or body[0] == '=') return null;
    if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
        return .{ .name = body[0..eq], .value = body[eq + 1 ..] };
    }
    return .{ .name = body, .value = null };
}

test splitLongFlag {
    const with_value = splitLongFlag("--port=9999").?;
    try std.testing.expectEqualStrings("port", with_value.name);
    try std.testing.expectEqualStrings("9999", with_value.value.?);
    try std.testing.expect(splitLongFlag("--=value") == null);
}

/// Return the value attached to a short flag token, if present.
pub fn attachedShortValue(tok: []const u8) ?[]const u8 {
    std.debug.assert(isShortFlag(tok));
    if (tok.len <= 2) return null;
    const rest = tok[2..];
    return if (rest[0] == '=') rest[1..] else rest;
}

test isShortFlag {
    try std.testing.expect(isShortFlag("-v"));
    try std.testing.expect(isShortFlag("-p9999"));
    try std.testing.expect(!isShortFlag("--foo"));
    try std.testing.expect(!isShortFlag("-"));
    try std.testing.expect(!isShortFlag("foo"));
}

/// True for the bare `--` end-of-options separator.
pub fn isOptionsTerminator(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "--");
}

test isOptionsTerminator {
    try std.testing.expect(isOptionsTerminator("--"));
    try std.testing.expect(!isOptionsTerminator("--foo"));
    try std.testing.expect(!isOptionsTerminator("-"));
}
