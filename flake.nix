{
  description = "nixserv host configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    pve-podman.url = "github:rkarsnk/PVE-podman/for-nixos";
    pve-podman.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, pve-podman, ... }: {
    nixosConfigurations.nixserv = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./nixos/configuration.nix
        pve-podman.nixosModules.default
        ./nixos/proxmox
      ];
    };
  };
}

