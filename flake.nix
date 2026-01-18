{
  description = "Lemon - A CLI frontend for macOS Virtualization.framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zigpkgs."0.15.2"
            zls
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            apple-sdk_15
          ];

          shellHook = ''
            echo "🍋 Lemon development environment"
            echo "Zig: $(zig version)"
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "lemon";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.zigpkgs."0.15.2" ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.apple-sdk_15
          ];

          # codesign requires network access for timestamp/notarization checks
          __darwinAllowLocalNetworking = true;

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local-cache
            zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/lemon $out/bin/
          '';

          # codesign after fixup (strip) to avoid invalidating the signature
          postFixup = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
            /usr/bin/codesign -f --entitlements ${./lemon.entitlements} -s - $out/bin/lemon
          '';
        };
      }
    );
}
