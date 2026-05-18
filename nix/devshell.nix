{ pkgs, inputs, system }:

let
  zig = import ./zig.nix { inherit inputs system; };
in
pkgs.mkShell {
  packages = [
    zig
  ];

  shellHook = ''
    echo "zig-cli-kit: $(zig version)"
  '';
}
