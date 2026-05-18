{
  description = "zig-cli-kit — small Zig CLI parsing toolkit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zignix.url = "github:withre/zignix";
    zignix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        }) systems);
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import inputs.nixpkgs { inherit system; };
        in {
          default = import ./nix/devshell.nix { inherit pkgs inputs system; };
        });

      packages = forAllSystems (system:
        let
          pkgs = import inputs.nixpkgs { inherit system; };
        in {
          default = import ./nix/packages/zig-cli-kit { inherit pkgs inputs system; };
        });

      checks = forAllSystems (system:
        let
          pkgs = import inputs.nixpkgs { inherit system; };
        in {
          zig-cli-kit-test = import ./nix/checks/zig-cli-kit-test { inherit pkgs inputs system; };
          zig-cli-kit-test-zig-master = import ./nix/checks/zig-cli-kit-test-zig-master { inherit pkgs inputs system; };
        });
    };
}
