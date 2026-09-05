{ pkgs, inputs, system }:

let
  zig = import ../../zig.nix { inherit inputs system; };
in
pkgs.stdenv.mkDerivation {
  pname = "zig-cli-kit";
  version = "0.1.0";

  src = ../../..;

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # `zig build` no longer takes --global-cache-dir; the env var is the
    # supported override (see `zig env`). --cache-dir is still a flag.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

    zig build --cache-dir "$TMPDIR/zig-cache" -Doptimize=ReleaseSafe

    runHook postBuild
  '';

  # Zig modules are source-distributed; the build phase is a smoke test.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/zig-cli-kit"
    cp -R src build.zig build.zig.zon "$out/share/zig-cli-kit/"

    runHook postInstall
  '';

  meta = {
    description = "Small Zig CLI parsing toolkit";
    license = pkgs.lib.licenses.mit;
  };
}
