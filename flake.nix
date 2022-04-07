{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) mkShell;
      in
      {
        devShells.default = mkShell {
          buildInputs = with pkgs; [
            zola
          ];
        };

        packages.hello = nixpkgs.legacyPackages.${system}.hello;

        defaultPackage = self.packages.${system}.hello;

      });
}
