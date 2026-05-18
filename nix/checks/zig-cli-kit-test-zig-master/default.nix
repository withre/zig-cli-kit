{ pkgs, inputs, system }:

let
  zig = import ../../zig.nix { inherit inputs system; channel = "master"; };
in
pkgs.stdenv.mkDerivation {
  name = "zig-cli-kit-test-zig-master";
  version = "0.1.0";

  src = ../../..;

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$XDG_CACHE_HOME"

    zig build test \
      --cache-dir "$TMPDIR/zig-cache" \
      --global-cache-dir "$TMPDIR/zig-global-cache"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    echo "Tests passed with Zig 0.17 development" > "$out/result"

    runHook postInstall
  '';

  meta = {
    description = "Test suite for zig-cli-kit with Zig 0.17 development";
  };
}
