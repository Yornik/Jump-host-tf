terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      version = "~> 1.42.1"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_server" "jump" {
  name        = "jump-host"
  server_type = "cax21"
  image       = "ubuntu-22.04"
  location    = "fsn1" # or nbg1 / hel1
  ssh_keys    = [hcloud_ssh_key.default.id]
  ipv6        = true
}

resource "hcloud_ssh_key" "default" {
  name       = "my-ssh-key"
  public_key = file("~/.ssh/id_ed25519.pub")
}
