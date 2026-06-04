{ pkgs, inputs, system }:

let
  zig = inputs.zignix.lib.${system};
  zig_0_16 = import ./zig.nix { inherit inputs system; };
  zig_0_17 = import ./zig.nix { inherit inputs system; channel = "master"; };
  # zignix's `withName` renames a package's `zig` binary, so the 0.16
  # baseline is exposed as `zig-0.16` with no collision against the
  # primary `zig` (0.17 development line) from zig_0_17.
  zig_0_16_bin = zig.withName "zig-0.16" zig_0_16;
in
pkgs.mkShell {
  packages = [
    zig_0_17
    zig_0_16_bin
  ];
}
