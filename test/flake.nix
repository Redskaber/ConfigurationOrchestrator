{
  description = "ConfigurationOrchestrator — test suite";

  inputs = {
    nixpkgs.url                    = "github:NixOS/nixpkgs/nixos-unstable";
    configuration-orchestrator.url = "github:redskaber/ConfigurationOrchestrator";
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
