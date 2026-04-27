{
  description = "ConfigurationOrchestrator — test suite";

  inputs = {
    nixpkgs.url                    = "github:NixOS/nixpkgs/nixos-unstable";
    # path:.. resolves to the parent directory (the library itself).
    # This means local changes to lib/ take effect immediately without
    # needing a push to GitHub. Run `nix flake update` only when you
    # want to pull a specific pinned remote revision.
    configuration-orchestrator.url = "path:..";
    hypr-config.url                = "github:redskaber/hypr-config";
    hypr-config.flake              = false;
  };

  outputs = { self, nixpkgs, configuration-orchestrator, hypr-config }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      orc  = configuration-orchestrator.lib.x86_64-linux;
    in
    import ./default.nix { inherit pkgs orc hypr-config; };
}
