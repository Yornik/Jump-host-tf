{ config, lib, ... }:

{
  disko.devices = {
    disk = {
      device = "/dev/sda"; # Adjust based on your actual disk
      type = "disk";
      content = {
        type = "gpt";
        partitions = [
          {
            name = "ESP";
            type = "EF00";
            size = "512M";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          }
          {
            name = "root";
            type = "8300";
            size = "100%"; # Use the remaining space
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          }
        ];
      };
    };
  };
}

