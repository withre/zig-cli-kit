{ inputs, system }:

# Zig toolchain used by this project, pinned through zignix.
#
# The project tracks the Zig `master` nightly (the 0.17 development line)
# as its single toolchain: `minimum_zig_version` in build.zig.zon is set to
# the exact nightly zignix's `zig-master` resolves to, and the devshell,
# package, and check all use that same binary. The revision is pinned via
# flake.lock; bump it with `nix flake update zignix` and then raise
# `minimum_zig_version` to match `zig version`.
inputs.zignix.packages.${system}.zig-master
