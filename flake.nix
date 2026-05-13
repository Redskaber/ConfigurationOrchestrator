# ConfigurationOrchestrator — flake.nix  (v4)
#
# Public interface: lib.<system>
#
# Supported systems: x86_64-linux  aarch64-linux  x86_64-darwin  aarch64-darwin
{
  description = "ConfigurationOrchestrator — per-file emitter control for home-manager config trees";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # lib.<system> — the pure function library
      lib = nixpkgs.lib.genAttrs systems
        (system:
          import ./lib/default.nix { lib = nixpkgs.lib; }
        );

      # packages.<system>.default — a simple passthrough package for nix flake show
      packages = forAllSystems (pkgs: {
        default = pkgs.runCommand "configuration-orchestrator" { } ''
          mkdir -p $out/lib
          cp ${./lib/default.nix} $out/lib/default.nix
        '';
      });
    };
}
