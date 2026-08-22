{
  home-manager,
  pkgs,
  self,
}:

home-manager.lib.homeManagerConfiguration {
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
}
