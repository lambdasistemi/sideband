{
  description =
    "sideband — Telegram side channel for unattended coding agents";
  inputs = {
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    dev-assets-mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
  };
  outputs =
    inputs@{ self, nixpkgs, flake-utils, haskellNix, dev-assets-mkdocs, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          overlays = [ haskellNix.overlay ];
          inherit system;
        };
        project = import ./nix/project.nix { inherit pkgs; };
        mkdocsPackages = dev-assets-mkdocs.packages.${system};
        site = pkgs.stdenv.mkDerivation {
          name = "sideband-docs";
          src = ./.;
          buildInputs = [ mkdocsPackages.from-nixpkgs ];
          buildPhase = "mkdocs build -d $out";
          dontInstall = true;
        };
      in {
        packages = project.packages // {
          default = project.packages.main;
          inherit site;
          docs = site;
        };
        inherit (project) devShells;
      }) // {
        nixosModules = rec {
          sideband = import ./nix/module.nix { inherit self; };
          default = sideband;
        };
      };
}
