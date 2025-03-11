{
  description = "NixOS Jump Host with Caddy, Docker, Headscale, PowerDNS, PowerDNS-Admin, Auto-Updates";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    disko.url = "github:nix-community/disko";
    nixos-facter-modules.url = "github:nix-community/nixos-facter-modules";
  };

  outputs = { self, nixpkgs, disko, nixos-facter-modules }: {
    nixosConfigurations.jump = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        disko.nixosModules.disko
        ./disko-config.nix
        nixos-facter-modules.nixosModules.facter
        { facter.reportPath = ./facter.json; }
        ({ config, pkgs, ... }:
        let
          secrets = import ./secrets.nix;
        in {
          imports = [ ];
          networking.hostName = "jump";
          networking.firewall.allowedTCPPorts = [ 22 80 443 53 8081 9191 ];

          time.timeZone = "Europe/Amsterdam";

          i18n.defaultLocale = "en_US.UTF-8";
          console.keyMap = "us";

          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = true;
          boot.loader.efi.efiSysMountPoint = "/boot";
          boot.initrd.kernelModules = [ "virtio_gpu" ];
          boot.kernelParams = [ "console=tty" ];
          services.openssh.enable = true;


          users.users.root = {
            isNormalUser = false;
            initialPassword = "changeme";
            openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOiJ5UN3roep5TtAbYpncz3ePiPpAU5PZSFHthCsyq3f unbuntu-on-windows-privepc"
            ];
          };

          environment.systemPackages = with pkgs; [
            vim
            curl
            git
            docker
            docker-compose
            caddy
            sqlite
          ];

          virtualisation.docker.enable = true;

          services.powerdns = {
            enable = true;
            extraConfig = ''
              launch=gsqlite3
              gsqlite3-database=/var/lib/pdns/pdns.sqlite3
              api=yes
              api-key=${secrets.pdnsApiKey}
              webserver=yes
              webserver-address=127.0.0.1
              webserver-port=8081
              default-ttl=60
              allow-axfr-ips=127.0.0.1
            '';
          };

          services.prometheus.exporters.node = {
            enable = true;
            port = 9100;
            listenAddress = "127.0.0.1";
            openFirewall = false;
          };

          services.resolved = {
          enable = true;};

          services.caddy = {
            enable = true;
            virtualHosts."jump.yornik.nl".extraConfig = ''
                handle_path /tailscale* {
                  reverse_proxy 127.0.0.1:3001 {
                    transport http {
                      tls_insecure_skip_verify
                    }
                  }
                }

                handle_path /dns* {
                  reverse_proxy 127.0.0.1:9191 {
                    transport http {
                      tls_insecure_skip_verify
                    }
                  }
                }

                handle {
                  reverse_proxy 127.0.0.1:8080
                }
            '';
          };

            systemd.tmpfiles.rules = [
             "d /opt/headscale 0755 root root -"
             "d /opt/headscale/data 0755 root root -"
             "d /opt/pdns-admin 0755 root root -"
            ];
          systemd.services.headscale-docker = {
            description = "Headscale Docker Compose";
            after = [ "network.target" "docker.service" ];
            requires = [ "docker.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "/run/current-system/sw/bin/docker-compose -f /opt/headscale/docker-compose.yml up";
              ExecStop = "/run/current-system/sw/bin/docker-compose -f /opt/headscale/docker-compose.yml down";
              WorkingDirectory = "/opt/headscale";
              Restart = "always";
            };
          };

          systemd.services.headscale-admin = {
            description = "Headscale Admin UI Docker Compose";
            after = [ "network.target" "docker.service" ];
            requires = [ "docker.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "/run/current-system/sw/bin/docker-compose -f /opt/headscale/docker-compose-admin.yml up";
              ExecStop = "/run/current-system/sw/bin/docker-compose -f /opt/headscale/docker-compose-admin.yml down";
              WorkingDirectory = "/opt/headscale";
              Restart = "always";
            };
          };

          systemd.services.pdns-admin = {
            description = "PowerDNS-Admin Docker Compose";
            after = [ "network.target" "docker.service" ];
            requires = [ "docker.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "/run/current-system/sw/bin/docker-compose -f /opt/pdns-admin/docker-compose.yml up";
              ExecStop = "/run/current-system/sw/bin/docker-compose -f /opt/pdns-admin/docker-compose.yml down";
              WorkingDirectory = "/opt/pdns-admin";
              Restart = "always";
            };
          };

          system.autoUpgrade = {
            enable = true;
            allowReboot = true;
          };

          system.stateVersion = "24.11";
        })
      ];
    };
  };
}

