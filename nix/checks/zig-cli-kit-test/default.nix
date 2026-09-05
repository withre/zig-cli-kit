{ pkgs, inputs, system }:

let
  zig = import ../../zig.nix { inherit inputs system; };
in
pkgs.stdenv.mkDerivation {
  name = "zig-cli-kit-test";
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

    zig build test --cache-dir "$TMPDIR/zig-cache"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    echo "Tests passed" > "$out/result"

    runHook postInstall
  '';

  meta = {
    description = "Test suite for zig-cli-kit";
  };
}
