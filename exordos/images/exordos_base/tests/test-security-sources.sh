#!/usr/bin/env bash
# Copyright 2026 Genesis Corporation. Licensed under the Apache License, Version 2.0.
set -euo pipefail

image_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sources="$image_dir/etc/apt/sources.list"

# Security packages must remain available when an ordinary mirror lags behind.
awk '
    $1 == "deb" && $2 == "https://security.ubuntu.com/ubuntu" && $3 == "release-security" { found = 1 }
    END { exit !found }
' "$sources"

# A failed security index download must stop image publication.
grep -Eq '^[[:space:]]*sudo apt-get update -o APT::Update::Error-Mode=any([[:space:]]|$)' "$image_dir/install.sh"
echo "Signed Ubuntu security updates are required for image builds"
