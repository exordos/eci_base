#!/usr/bin/env bash
# Copyright 2026 Genesis Corporation
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Check the installed files, including ownership copied from build artifacts.
LIBRARY_DIR="${1:-/usr/local/lib/exordos}"
LIBRARY_PATH="$LIBRARY_DIR/lib_bootstrap.sh"

[[ -d "$LIBRARY_DIR" && ! -L "$LIBRARY_DIR" ]]
[[ -f "$LIBRARY_PATH" && ! -L "$LIBRARY_PATH" ]]

DIRECTORY_METADATA=$(stat -c '%u:%g:%a' "$LIBRARY_DIR")
LIBRARY_METADATA=$(stat -c '%u:%g:%a' "$LIBRARY_PATH")

if [[ "$DIRECTORY_METADATA" != 0:0:755 || "$LIBRARY_METADATA" != 0:0:644 ]]; then
    printf 'Unexpected bootstrap library ownership/mode: directory=%s library=%s\n' \
        "$DIRECTORY_METADATA" "$LIBRARY_METADATA" >&2
    exit 1
fi

SCRIPT_DIR=$(dirname -- "$0")
cmp -- "$SCRIPT_DIR/../lib/lib_bootstrap.sh" "$LIBRARY_PATH"

echo "Bootstrap library ownership and permissions are correct"
