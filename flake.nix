# ConfigurationOrchestrator — root flake
# Exposes lib.<system> for all supported systems.
{
  description = "ConfigurationOrchestrator: per-file emitter control for home-manager config trees";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      # Primary export: orc = inputs.configuration-orchestrator.lib.${pkgs.system}
      lib = forAllSystems (system:
        import ./lib/default.nix { lib = nixpkgs.lib; }
      );

      # Formatter for `nix fmt`
      formatter = forAllSystems (system:
        nixpkgs.legacyPackages.${system}.nixpkgs-fmt
      );
    };
}
