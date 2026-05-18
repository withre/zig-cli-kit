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

    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$XDG_CACHE_HOME"

    zig build \
      --cache-dir "$TMPDIR/zig-cache" \
      --global-cache-dir "$TMPDIR/zig-global-cache" \
      -Doptimize=ReleaseSafe

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
