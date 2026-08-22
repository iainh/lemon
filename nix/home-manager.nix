{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatMap
    filterAttrs
    intersectLists
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.lemon;
  toml = pkgs.formats.toml { };
  configDirectory = "${config.home.homeDirectory}/Library/Application Support/dev.lemon.lemon";
  dataDirectory = configDirectory;
  logDirectory = "${dataDirectory}/logs";

  vmModule = {
    options = {
      cpus = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Number of virtual CPUs.";
      };

      memoryMiB = mkOption {
        type = types.ints.positive;
        default = 2048;
        description = "Memory allocated to the VM in MiB.";
      };

      macAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "02:00:00:00:00:01";
        description = ''
          Stable MAC address for the VM. By default, Lemon derives a locally
          administered address from the VM name.
        '';
      };

      disks = mkOption {
        type = types.listOf types.str;
        description = ''
          Writable raw disk image paths. Keep these outside the Nix store.
        '';
      };

      boot = {
        kernel = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Uncompressed Linux kernel path; null selects EFI boot.";
        };

        initrd = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional Linux initramfs path.";
        };

        cmdline = mkOption {
          type = types.str;
          default = "console=hvc0 rw";
          description = "Linux kernel command line.";
        };
      };

      ssh = {
        authorizedKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "ssh-ed25519 AAAA... user@example";
          description = "Public SSH key provisioned through cloud-init.";
        };

        user = mkOption {
          type = types.str;
          default = "lemon";
          description = "Guest user provisioned through cloud-init.";
        };
      };

      service = {
        enable = mkEnableOption "a launchd service for this VM";

        restart = mkOption {
          type = types.bool;
          default = true;
          description = "Restart the VM when its runtime exits.";
        };
      };
    };
  };

  containerModule = {
    options = {
      image = mkOption {
        type = types.str;
        description = "OCI image name used by Apple container.";
        example = "ghcr.io/hotio/nzbget";
      };

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Start the container when the Home Manager generation is activated.";
      };

      ports = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Port mappings in host:container form.";
        example = [ "6789:6789" ];
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment variables passed to the container.";
      };

      volumes = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Volume mappings in host:container form.";
        example = [ "/mnt/config/nzbget:/config" ];
      };

      cpus = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Optional CPU limit.";
      };

      memory = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "2G";
        description = "Optional memory limit.";
      };

      cmd = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Command and arguments that override the image default.";
      };

      restart = mkOption {
        type = types.bool;
        default = true;
        description = "Restart the container when its runtime exits.";
      };
    };
  };

  yamlString = value: "'${lib.replaceStrings [ "'" ] [ "''" ] value}'";

  derivedMacAddress =
    name:
    let
      hash = builtins.hashString "sha256" "lemon:${name}";
    in
    lib.concatStringsSep ":" (
      [ "02" ]
      ++ map (offset: builtins.substring offset 2 hash) [
        0
        2
        4
        6
        8
      ]
    );

  cloudInit =
    name: vm:
    let
      userData = pkgs.writeText "lemon-${name}-user-data" ''
        #cloud-config
        users:
          - name: ${yamlString vm.ssh.user}
            lock_passwd: true
            shell: /bin/sh
            sudo: ALL=(ALL) NOPASSWD:ALL
            ssh_authorized_keys:
              - ${yamlString vm.ssh.authorizedKey}
        ssh_pwauth: false
        disable_root: true
      '';
      metaData = pkgs.writeText "lemon-${name}-meta-data" ''
        instance-id: ${yamlString "lemon-${name}"}
        local-hostname: ${yamlString name}
      '';
    in
    {
      user = vm.ssh.user;
      user_data = toString userData;
      meta_data = toString metaData;
    };

  vmConfig =
    name: vm:
    {
      inherit name;
      inherit (vm) cpus disks;
      memory_mib = vm.memoryMiB;
      mac_address = if vm.macAddress == null then derivedMacAddress name else vm.macAddress;
      boot =
        if vm.boot.kernel == null then
          {
            type = "efi";
            variable_store = "${dataDirectory}/vms/${name}/efi-vars";
          }
        else
          {
            type = "linux";
            kernel = vm.boot.kernel;
            cmdline = vm.boot.cmdline;
          }
          // lib.optionalAttrs (vm.boot.initrd != null) {
            initrd = vm.boot.initrd;
          };
    }
    // lib.optionalAttrs (vm.ssh.authorizedKey != null) {
      cloud_init = cloudInit name vm;
    };

  vmServices = filterAttrs (_: vm: vm.service.enable) cfg.vms;
  containerServices = filterAttrs (_: container: container.autoStart) cfg.containers;

  containerConfig =
    name: container:
    {
      inherit name;
      inherit (container) image restart volumes;
      type = "container";
      env = mapAttrsToList (key: value: "${key}=${value}") container.environment;
      publish = container.ports;
      command = container.cmd;
    }
    // lib.optionalAttrs (container.cpus != null) { inherit (container) cpus; }
    // lib.optionalAttrs (container.memory != null) { inherit (container) memory; };

  definitionFiles =
    mapAttrs' (
      name: vm:
      nameValuePair "Library/Application Support/dev.lemon.lemon/vms/${name}.toml" {
        source = toml.generate "lemon-vm-${name}.toml" (vmConfig name vm);
      }
    ) cfg.vms
    // mapAttrs' (
      name: vm:
      nameValuePair "Library/Application Support/dev.lemon.lemon/services/${name}.toml" {
        source = toml.generate "lemon-service-${name}.toml" {
          inherit name;
          restart = vm.service.restart;
          type = "vm";
          vm = name;
        };
      }
    ) vmServices
    // mapAttrs' (
      name: container:
      nameValuePair "Library/Application Support/dev.lemon.lemon/services/${name}.toml" {
        source = toml.generate "lemon-service-${name}.toml" (containerConfig name container);
      }
    ) cfg.containers;

  agent =
    name: restart: runtimePackage: runtimeName:
    nameValuePair "lemon-${name}" {
      enable = true;
      config = {
        Label = "dev.lemon.${name}";
        ProgramArguments = [
          "${cfg.package}/bin/lemon"
          "run-service"
          name
        ];
        RunAtLoad = true;
        KeepAlive = restart;
        ProcessType = "Background";
        ThrottleInterval = 5;
        ExitTimeOut = 15;
        EnvironmentVariables = {
          LEMON_CONFIG_DIR = configDirectory;
          LEMON_DATA_DIR = dataDirectory;
          LEMON_RUNTIME = "${runtimePackage}/bin/${runtimeName}";
          PATH = lib.makeBinPath [ runtimePackage ];
        };
        StandardOutPath = "${logDirectory}/${name}.log";
        StandardErrorPath = "${logDirectory}/${name}.error.log";
      };
    };

  agents =
    mapAttrs' (name: vm: agent name vm.service.restart pkgs.vfkit "vfkit") vmServices
    // mapAttrs' (
      name: container: agent name container.restart cfg.containerPackage "container"
    ) containerServices;

  validName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;

  vmAssertions = concatMap (
    name:
    let
      vm = cfg.vms.${name};
    in
    [
      {
        assertion = validName name;
        message = "services.lemon.vms.${name}: the name is not valid for Lemon";
      }
      {
        assertion = vm.disks != [ ];
        message = "services.lemon.vms.${name}.disks must contain at least one disk";
      }
      {
        assertion = vm.boot.initrd == null || vm.boot.kernel != null;
        message = "services.lemon.vms.${name}.boot.initrd requires boot.kernel";
      }
    ]
  ) (builtins.attrNames cfg.vms);

  containerAssertions = map (name: {
    assertion = validName name;
    message = "services.lemon.containers.${name}: the name is not valid for Lemon";
  }) (builtins.attrNames cfg.containers);
in
{
  options.services.lemon = {
    enable = mkEnableOption "declarative Lemon virtual machines and containers";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "lemon.packages.${pkgs.system}.default";
      description = "Lemon package used by the generated LaunchAgents.";
    };

    containerPackage = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.container-runtime;
      defaultText = lib.literalExpression "lemon.packages.${pkgs.system}.container-runtime";
      description = "Apple container package used by container LaunchAgents.";
    };

    vms = mkOption {
      type = types.attrsOf (types.submodule vmModule);
      default = { };
      description = "Declarative Lemon VM definitions.";
    };

    containers = mkOption {
      type = types.attrsOf (types.submodule containerModule);
      default = { };
      description = "Declarative Lemon container services.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      vmAssertions
      ++ containerAssertions
      ++ [
        {
          assertion =
            intersectLists (builtins.attrNames vmServices) (builtins.attrNames cfg.containers) == [ ];
          message = "a Lemon VM service and container cannot have the same name";
        }
      ];
    home = {
      packages = [ cfg.package ];
      file = definitionFiles;
      activation = {
        lemonDirectories = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg logDirectory}
        '';
        setupLaunchAgents = lib.hm.dag.entryAfter [
          "lemonDirectories"
          "linkGeneration"
        ] (lib.mkDefault "");
      };
    };
    launchd.agents = agents;
  };
}
