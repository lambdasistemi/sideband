{ pkgs }:
let
  project = pkgs.haskell-nix.cabalProject' {
    src = pkgs.haskell-nix.cleanSourceHaskell {
      src = ./..;
      name = "sideband";
    };
    compiler-nix-name = "ghc9123";
    shell = { ... }: {
      tools = {
        cabal = { };
        fourmolu = { };
        hlint = { };
        hoogle = { };
      };
      buildInputs = with pkgs; [ just nixfmt-classic shellcheck ];
    };
  };
in {
  packages = {
    main = project.hsPkgs.sideband.components.exes.tg;
    unit-tests = project.hsPkgs.sideband.checks.unit;
  };
  devShells.default = project.shell;
}
