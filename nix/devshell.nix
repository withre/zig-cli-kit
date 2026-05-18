{ pkgs, inputs, system }:

let
  zig_0_16 = import ./zig.nix { inherit inputs system; };
  zig_0_17 = import ./zig.nix { inherit inputs system; channel = "master"; };
  zig_0_16_bin = pkgs.writeShellScriptBin "zig-0.16" ''
    exec ${zig_0_16}/bin/zig "$@"
  '';
in
pkgs.mkShell {
  # Order matters: zig_0_17 first so its `bin/zig` wins on PATH.
  packages = [
    zig_0_17
    zig_0_16_bin
  ];
}
