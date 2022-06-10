#!/usr/bin/env bash
set -e

# Fetch the latest code
git pull

# Run the VOPR
zig/zig run ./src/vopr.zig -- --send="127.0.0.1:5555"
