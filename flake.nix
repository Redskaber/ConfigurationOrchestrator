{
  description = "ConfigurationOrchestrator — pure-Nix config directory reader library";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems      = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # Usage:
      #   inputs.orchestrator.url = "github:redskaber/ConfigurationOrchestrator";
      #   orc = inputs.orchestrator.lib.${pkgs.system};
      lib = forAllSystems (system:
        import ./lib { lib = nixpkgs.legacyPackages.${system}.lib; }
      );
    };
}
