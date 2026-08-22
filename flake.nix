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
      moduleTest = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          self.homeModules.default
          {
            home = {
              username = "lemon-test";
              homeDirectory = "/Users/lemon-test";
              stateVersion = "24.11";
            };
            services.lemon = {
              enable = true;
              containers.nzbget = {
                image = "ghcr.io/hotio/nzbget";
                ports = [ "6789:6789" ];
                environment = {
                  PUID = "1000";
                  TZ = "America/Toronto";
                };
                volumes = [ "/Users/lemon-test/data:/data" ];
              };
              vms.test = {
                disks = [ "/Users/lemon-test/vms/test.raw" ];
                ssh.authorizedKey = "ssh-ed25519 AAAA lemon-test";
                service.enable = true;
              };
              vms.direct = {
                disks = [ "/Users/lemon-test/vms/direct.raw" ];
                boot.kernel = "/Users/lemon-test/vms/Image";
              };
            };
          }
        ];
      };
    in
    {
      homeModules.default = import ./nix/home-manager.nix { inherit self; };

      packages.${system} = {
        default = lemon;
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
      };

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
