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
            zigpkgs.master
            zls
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            darwin.apple_sdk.frameworks.Virtualization
            darwin.apple_sdk.frameworks.Foundation
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

          nativeBuildInputs = [ pkgs.zigpkgs.master ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Virtualization
            pkgs.darwin.apple_sdk.frameworks.Foundation
          ];

          buildPhase = ''
            zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/lemon $out/bin/
          '';
        };
      }
    );
}
