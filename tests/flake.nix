# ConfigurationOrchestrator — tests/flake.nix
#
# Run the test suite:
#   cd test
#   nix eval .#_summary
#   nix eval . --json | jq .layer3
#
# path:.. resolves to the parent directory (the library itself).
# Local changes to lib/ take effect immediately without a GitHub push.
# Run `nix flake update` only to pin a specific remote revision.
{
  description = "ConfigurationOrchestrator — test suite";

  inputs = {
    nixpkgs.url                    = "github:NixOS/nixpkgs/nixos-unstable";
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
