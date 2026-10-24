#!/usr/bin/env bash
# Gem Mesh: run this after cloning. See ./install.sh --help and README.md.
exec "$(cd "$(dirname "$0")" && pwd)/scripts/install.sh" "$@"
