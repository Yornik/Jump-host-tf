cat flake.nix
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
              local-port=5300
              default-ttl=60
              allow-axfr-ips=127.0.0.1
            '';
          };
          let
            pdnsSchema = pkgs.writeText "pdns-schema.sql" ''
              PRAGMA foreign_keys = 1;
          
              CREATE TABLE domains (
                id                    INTEGER PRIMARY KEY,
                name                  VARCHAR(255) NOT NULL COLLATE NOCASE,
                master                VARCHAR(128) DEFAULT NULL,
                last_check            INTEGER DEFAULT NULL,
                type                  VARCHAR(8) NOT NULL,
                notified_serial       INTEGER DEFAULT NULL,
                account               VARCHAR(40) DEFAULT NULL,
                options               VARCHAR(65535) DEFAULT NULL,
                catalog               VARCHAR(255) DEFAULT NULL
              );
          
              CREATE UNIQUE INDEX name_index ON domains(name);
              CREATE INDEX catalog_idx ON domains(catalog);
          
              CREATE TABLE records (
                id                    INTEGER PRIMARY KEY,
                domain_id             INTEGER DEFAULT NULL,
                name                  VARCHAR(255) DEFAULT NULL,
                type                  VARCHAR(10) DEFAULT NULL,
                content               VARCHAR(65535) DEFAULT NULL,
                ttl                   INTEGER DEFAULT NULL,
                prio                  INTEGER DEFAULT NULL,
                disabled              BOOLEAN DEFAULT 0,
                ordername             VARCHAR(255),
                auth                  BOOL DEFAULT 1,
                FOREIGN KEY(domain_id) REFERENCES domains(id) ON DELETE CASCADE ON UPDATE CASCADE
              );
          
              CREATE INDEX records_lookup_idx ON records(name, type);
              CREATE INDEX records_lookup_id_idx ON records(domain_id, name, type);
              CREATE INDEX records_order_idx ON records(domain_id, ordername);
          
              CREATE TABLE supermasters (
                ip                    VARCHAR(64) NOT NULL,
                nameserver            VARCHAR(255) NOT NULL COLLATE NOCASE,
                account               VARCHAR(40) NOT NULL
              );
          
              CREATE UNIQUE INDEX ip_nameserver_pk ON supermasters(ip, nameserver);
            '';
          in
          {
            systemd.services.pdns-init-db = {
              description = "Initialize PowerDNS SQLite Database";
              after = ["network.target"];
              wantedBy = ["multi-user.target"];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${pkgs.sqlite}/bin/sqlite3 /var/lib/powerdns/pdns.sqlite3 < ${pdnsSchema}";
                ExecStartPost = "${pkgs.coreutils}/bin/chown -R pdns:pdns /var/lib/powerdns";
                ExecStartPost = "${pkgs.coreutils}/bin/chmod 750 /var/lib/powerdns";
              };
            };
          }

          services.prometheus.exporters.node = {
            enable = true;
            port = 9100;
            listenAddress = "127.0.0.1";
            openFirewall = false;
          };

          services.resolved = {
          enable = false;};
          networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
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
          services.pdns-recursor = {
          enable = true;
          forwardZones = {
               "new.yornik.nl" = "127.0.0.1:5300";
           };
          };
          systemd.tmpfiles.rules = [
             "d /opt/headscale 0755 root root -"
             "d /opt/headscale/data 0755 root root -"
             "d /opt/pdns-admin 0755 root root -"
             "d /var/lib/pdns 0750 pdns pdns"
             "f /var/lib/pdns/pdns.sqlite3 0640 pdns pdns - -"
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
