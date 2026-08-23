{ inputs, ... }:
{
  imports = [ inputs.pve-podman.nixosModules.default ];

  services.pvePodman = {
    enable = true;
    parentIface = "enp1s0";
    bridgeName = "br0";
    subnet = "192.168.24.0/24";
    gateway = "192.168.24.1";
    pveIp = "192.168.24.51";
    pveDns = "192.168.24.1";
    extraVolumes = [ "/srvdata/proxmox:/datastore" ];
  };
}
