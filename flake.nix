{
  description =
    "sideband — Telegram side channel for unattended coding agents";
  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" "https://paolino.cachix.org" ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "paolino.cachix.org-1:ecmgO3CXdgSWA2cHlm4srknd/cLFMLmK3i3NrzeDFaE="
    ];
  };
  inputs = {
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    dev-assets-mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
    bundlers.url = "github:NixOS/bundlers";
  };
  outputs = inputs@{ self, nixpkgs, flake-utils, haskellNix, dev-assets-mkdocs
    , bundlers, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          overlays = [ haskellNix.overlay ];
          inherit system;
        };
        project = import ./nix/project.nix { inherit pkgs; };

        # The .cabal version is the release source of truth (PVP, x.y.z.w).
        versionMatch = builtins.match
          ".*\nversion:[[:space:]]+([0-9.]+).*"
          (builtins.readFile ./sideband.cabal);
        packageVersion = builtins.elemAt versionMatch 0;
        sourceRevision = self.shortRev or (self.dirtyShortRev or "dirty");
        devArtifactVersion = "${packageVersion}-${sourceRevision}";

        mkdocsPackages = dev-assets-mkdocs.packages.${system};
        site = pkgs.stdenv.mkDerivation {
          name = "sideband-docs";
          src = ./.;
          buildInputs = [ mkdocsPackages.from-nixpkgs ];
          buildPhase = "mkdocs build -d $out";
          dontInstall = true;
        };

        linuxReleasePackages = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          linux-release-artifacts = import ./nix/linux-release.nix {
            inherit pkgs system packageVersion bundlers;
            package = project.packages.main;
          };
          linux-dev-release-artifacts = import ./nix/linux-release.nix {
            inherit pkgs system packageVersion bundlers;
            artifactVersion = devArtifactVersion;
            package = project.packages.main;
          };
          linux-artifact-smoke =
            import ./nix/linux-artifact-smoke.nix { inherit pkgs system; };
        };
      in {
        packages = project.packages // linuxReleasePackages // {
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
        homeManagerModules = rec {
          sideband = import ./nix/home-module.nix { inherit self; };
          default = sideband;
        };
      };
}
