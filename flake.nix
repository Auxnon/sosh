{
  description = "sosh: floating islands to hang out on together";

  # Just the NixOS module (deploy/nixos/sosh.nix); the server itself is the
  # container image the Containerfile builds.
  outputs = { self }: {
    nixosModules.sosh = import ./deploy/nixos/sosh.nix;
    nixosModules.default = self.nixosModules.sosh;
  };
}
