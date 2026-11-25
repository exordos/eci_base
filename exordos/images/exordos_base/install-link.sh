#!/usr/bin/env bash
# Copyright 2026 Genesis Corporation
# Licensed under the Apache License, Version 2.0.
set -euo pipefail

arch=$(dpkg --print-architecture)
version=0.0.5
script_dir=$(dirname -- "${BASH_SOURCE[0]}")
filename="exordos-link_${version}_${arch}.deb"
digest=$(awk -v name="$filename" '$2 == name { print $1 }' "$script_dir/link.sha256")
if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "No trusted SHA-256 for $filename" >&2
    exit 1
fi

package="${EXORDOS_LINK_DEB:-$script_dir/$filename}"
if [[ -z ${EXORDOS_LINK_DEB:-} && ! -f "$package" ]]; then
    download=$(mktemp -d)
    trap 'rm -r -- "$download"' EXIT
    package="$download/$filename"
    curl -fLsS --proto '=https' --retry 3 \
        "https://github.com/exordos/exordos_link/releases/download/$version/$filename" \
        -o "$package"
fi
if [[ ! -f "$package" ]]; then
    echo "Link package required at $package" >&2
    exit 1
fi
printf '%s  %s\n' "$digest" "$package" | sha256sum --check -
test "$(dpkg-deb --field "$package" Package)" = exordos-link
test "$(dpkg-deb --field "$package" Version)" = "$version"
test "$(dpkg-deb --field "$package" Architecture)" = "$arch"
sudo dpkg -i "$package"
if ! id -u exordos-link >/dev/null 2>&1; then
    sudo useradd --system --user-group --shell /usr/sbin/nologin exordos-link
fi
