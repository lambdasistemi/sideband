# shellcheck shell=bash

# List available recipes
default:
    @just --list

# Build everything (dev, unoptimised)
build:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal build all -O0

# Run the unit tests
unit:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal test unit -O0 --test-show-details=direct

# Format all source files
format:
    #!/usr/bin/env bash
    set -euo pipefail
    fourmolu -i app src test
    nixfmt flake.nix nix/*.nix

# Check formatting without changing files
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fourmolu -m check app src test

# Run hlint
hlint:
    #!/usr/bin/env bash
    set -euo pipefail
    hlint app src test

# Everything CI runs
CI: build unit format-check hlint
