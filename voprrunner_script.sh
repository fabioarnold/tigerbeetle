#!/usr/bin/env bash
set -e

# Fetch the latest code
git pull

# Run the VOPR
zig/zig build vopr -- --send="65.21.207.251:5555"
