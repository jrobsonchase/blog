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
      rec {
        packages.default = pkgs.symlinkJoin {
          name = "blog";
          paths = [
            packages.stable
            packages.drafts
          ];
        };
        packages.stable = pkgs.callPackage ./build.nix { };
        packages.drafts = packages.stable.override {
          drafts = true;
        };
        devShells.default = mkShell {
          inputsFrom = [ packages.default ];
        };
      });
}
