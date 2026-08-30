{
  description = "Lemon VM and container launchd service manager";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      home-manager,
      nixpkgs,
    }:
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
        nativeBuildInputs = [ pkgs.makeWrapper ];

        postInstall = ''
          wrapProgram $out/bin/lemon \
            --prefix PATH : ${pkgs.lib.makeBinPath runtimePackages}
        '';

        meta = {
          description = "Run Linux VMs and containers as launchd services on macOS";
          license = pkgs.lib.licenses.mit;
          mainProgram = "lemon";
          platforms = [ system ];
        };
      };
      moduleTest = import ./nix/module-test.nix {
        inherit home-manager pkgs self;
      };
    in
    {
      homeModules.default = import ./nix/home-manager.nix { inherit self; };

      packages.${system} = {
        default = lemon;
        container-runtime = pkgs.container;
        inherit lemon;
      };

      apps.${system}.default = {
        type = "app";
        program = "${lemon}/bin/lemon";
        meta.description = "Run Lemon from the Nix store";
      };

      checks.${system} = {
        default = lemon;
        home-manager-module = moduleTest.activationPackage;
        nix =
          pkgs.runCommand "lemon-nix-check"
            {
              nativeBuildInputs = with pkgs; [
                deadnix
                statix
              ];
            }
            ''
              deadnix --fail ${self}
              statix check ${self}
              touch $out
            '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages =
          runtimePackages
          ++ testPackages
          ++ (with pkgs; [
            cargo
            clippy
            deadnix
            nixfmt-tree
            rustc
            rustfmt
            statix
          ]);
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
