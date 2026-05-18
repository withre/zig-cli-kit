{ inputs, system, channel ? "0.16" }:

# Zig toolchain used by this project, pinned through zignix.
#
# The project target is the Zig 0.17 development line (`channel = "master"`).
# The devshell uses it as the primary `zig` on PATH (see ./devshell.nix);
# `channel = "0.16"` selects the latest 0.16 release and remains the
# deployment-compatible baseline for `nix build` consumers until 0.17.0 is
# released. Both packages are maintained by zignix and pinned via flake.lock
# so each channel is reproducible. Bump them with `nix flake update zignix`.

let
  packages = inputs.zignix.packages.${system};
  byChannel = {
    "0.16" = packages.zig-0_16;
    "master" = packages.zig-master;
  };
in
byChannel.${channel}
