{
  description = "Lemon VM and container launchd service manager";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
      runtimePackages = with pkgs; [
        container
        openssh
        vfkit
      ];
      testPackages = with pkgs; [
        curl
        xz
      ];
      lemon = pkgs.rustPlatform.buildRustPackage {
        pname = "lemon";
        version = "0.1.0";
        src = self;

        cargoLock.lockFile = ./Cargo.lock;
        strictDeps = true;
        nativeBuildInputs = with pkgs; [
          makeWrapper
          pkg-config
        ];
        buildInputs = [ pkgs.xz ];

        postInstall = ''
          wrapProgram $out/bin/lemon \
            --prefix PATH : ${pkgs.lib.makeBinPath (runtimePackages ++ testPackages)}
        '';

        meta = {
          description = "Run Linux VMs and containers as launchd services on macOS";
          license = pkgs.lib.licenses.mit;
          mainProgram = "lemon";
          platforms = [ system ];
        };
      };
    in
    {
      packages.${system} = {
        default = lemon;
        inherit lemon;
      };

      apps.${system}.default = {
        type = "app";
        program = "${lemon}/bin/lemon";
        meta.description = "Run Lemon from the Nix store";
      };

      checks.${system}.default = lemon;

      devShells.${system}.default = pkgs.mkShell {
        packages =
          runtimePackages
          ++ testPackages
          ++ (with pkgs; [
            cargo
            clippy
            nixfmt-tree
            rustc
            rustfmt
          ]);
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
