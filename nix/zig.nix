{ inputs, system }:

# Zig toolchain used by this project.
#
# We track `mitchellh/zig-overlay`'s `master` channel, which mirrors
# upstream development builds. The exact revision is pinned through
# `flake.lock` — bump it deliberately with:
#
#     nix flake update zig-overlay
#
# If a stable 0.16.x release becomes available in the overlay and is
# preferred, switch to e.g. `packages.${system}."0.16.0"`.
inputs.zig-overlay.packages.${system}.master
