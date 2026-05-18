//! CLI Argument Parsing Library for Zig v0.16
//!
//! A declarative CLI library with:
//! - Global flags that work anywhere in the arg list
//! - Env var binding with flag > env > default priority
//! - Subcommand dispatch with aliases and nesting
//! - Mutual exclusivity enforcement
//! - Required flag validation
//! - `--` rest arg capture
//! - "Did you mean?" suggestions for unknown flags
//! - Negatable boolean flags (--no-X)
//! - TTY-aware coloured help output
//!
//! ## Module layout
//!
//! ```
//! root.zig                  ← this file (public re-exports)
//! cli/types.zig             ← App, Command, FlagDef, ArgDef, Context, etc.
//! cli/parse.zig             ← argument parsing and command dispatch
//! cli/parse/tokens.zig      ← token classifiers
//! cli/parse/resolve.zig     ← command resolution
//! cli/parse/globals.zig     ← global-flag parsing
//! cli/parse/args.zig        ← command-arg parsing
//! cli/help.zig              ← help output formatting
//! cli/colour.zig            ← named colour constants, TTY detection
//! cli/validate.zig          ← Levenshtein, suggestions, flag lookup, validation
//! ```

const std = @import("std");

pub const App = @import("cli/types.zig").App;
pub const Command = @import("cli/types.zig").Command;
pub const FlagDef = @import("cli/types.zig").FlagDef;
pub const ArgDef = @import("cli/types.zig").ArgDef;
pub const HelpSection = @import("cli/types.zig").HelpSection;
pub const HelpEntry = @import("cli/types.zig").HelpEntry;
pub const Context = @import("cli/types.zig").Context;
pub const Error = @import("cli/types.zig").Error;
pub const ParseError = @import("cli/types.zig").ParseError;

// Pull in all sub-module tests when `zig build test` runs on this file.
comptime {
    std.debug.assert(@hasDecl(@import("cli/types.zig"), "App"));
    std.debug.assert(@hasDecl(@import("cli/parse.zig"), "run"));
    std.debug.assert(@hasDecl(@import("cli/help.zig"), "printRootHelp"));
    std.debug.assert(@hasDecl(@import("cli/colour.zig"), "Palette"));
    std.debug.assert(@hasDecl(@import("cli/validate.zig"), "lookupEnv"));
}

test "public API re-exports documented symbols" {
    try std.testing.expect(@sizeOf(App) > 0);
    try std.testing.expect(@sizeOf(Command) > 0);
    try std.testing.expect(@sizeOf(FlagDef) > 0);
    try std.testing.expect(@sizeOf(ArgDef) > 0);
    try std.testing.expect(@sizeOf(HelpSection) > 0);
    try std.testing.expect(@sizeOf(HelpEntry) > 0);
    try std.testing.expect(@sizeOf(Context) > 0);

    const err: Error = error.UnknownFlag;
    try std.testing.expect(err == error.UnknownFlag);
    try std.testing.expect(@TypeOf(err) == ParseError);
}
