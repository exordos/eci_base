#!/usr/bin/env bash

# Copyright 2025-2026 Genesis Corporation
#
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -eu
set -x
set -o pipefail

AGENT_PATH="/opt/universal_agent"
IMG_ARTS_PATH="/opt/eci_base/exordos/images/exordos_base"
WORK_DIR="/var/lib/exordos"
SYSTEMD_SERVICE_DIR=/etc/systemd/system/

PASSWD="${GEN_USER_PASSWD:-ubuntu}"
SDK_PATH="/opt/gcl_sdk"
DEV_MODE=$([ -d "$SDK_PATH" ] && echo "true" || echo "false")

if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sudo mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
fi
if [ -f /etc/apt/sources.list ]; then
    sudo mv /etc/apt/sources.list /etc/apt/sources.list.bak
fi
sudo cp "$IMG_ARTS_PATH/etc/apt/sources.list" /etc/apt/sources.list
sudo sed -i "s/release/$(lsb_release -cs)/g" /etc/apt/sources.list

sudo sed -i 's/^preserve_hostname: false/preserve_hostname: false\napt_preserve_sources_list: true/' /etc/cloud/cloud.cfg

# Install packages
sudo apt update
sudo apt dist-upgrade -y
sudo apt install -y build-essential python3-dev python3-venv \
    cloud-guest-utils irqbalance qemu-guest-agent libev-dev rsync parted j2cli vim \
    xfsprogs jq tar rsyslog systemd-journal-remote

export UV_INSTALL_DIR="/usr/local/bin"
curl --fail --show-error --location --progress-bar https://repo.exordos.com/uv/0.11.11/uv --output "${UV_INSTALL_DIR}/uv"
chmod +x "${UV_INSTALL_DIR}/uv"
#export UV_INSTALLER_GHE_BASE_URL=https://github.com
#curl -LsSf https://github.com/astral-sh/uv/releases/download/0.11.7/uv-installer.sh | sh
uv self version

# Install the Core Agent
# Prepare a fresh virtual environment
rm -fr "$AGENT_PATH/.venv"
mkdir -p "$AGENT_PATH/.venv"
python3 -m venv "$AGENT_PATH/.venv"
source "$AGENT_PATH"/.venv/bin/activate
pip install pip --upgrade

# In the dev mode the exordos_core package is installed from the local machine
if [[ "$DEV_MODE" == "true" ]]; then
    uv pip install -e "$SDK_PATH"
# Install the Core Agent as a package from pypi
else
    uv pip install gcl-sdk=="$GEN_SDK_VERSION"
fi

sudo cp -r "$IMG_ARTS_PATH/etc/exordos_universal_agent" /etc/
sudo ln -sf "$AGENT_PATH/.venv/bin/exordos-universal-agent" "/usr/bin/exordos-universal-agent"


# Install stuff for bootstrap procedure and systemd services
sudo mkdir -p "$WORK_DIR/bootstrap/scripts/"
sudo cp "$IMG_ARTS_PATH/bootstrap.sh" "$WORK_DIR/bootstrap/"
sudo cp "$IMG_ARTS_PATH/exordos_autoresize.sh" "/usr/bin/"
sudo cp "$IMG_ARTS_PATH/etc/systemd/exordos-bootstrap.service" $SYSTEMD_SERVICE_DIR
sudo cp "$IMG_ARTS_PATH/etc/systemd/exordos-autoresize.service" $SYSTEMD_SERVICE_DIR
sudo cp "$IMG_ARTS_PATH/etc/systemd/exordos-autoresize@.service" $SYSTEMD_SERVICE_DIR
sudo cp "$IMG_ARTS_PATH/etc/systemd/exordos-universal-agent.service" $SYSTEMD_SERVICE_DIR
sudo cp "$IMG_ARTS_PATH/etc/udev/90-exordos-autoresize.rules" /etc/udev/rules.d/
sudo mkdir -p "/usr/local/lib/exordos/"
sudo cp -a "$IMG_ARTS_PATH/lib/." "/usr/local/lib/exordos/"

# Enable exordos core services
sudo systemctl enable exordos-bootstrap exordos-autoresize exordos-universal-agent

# Install observability agents: vmagent, vlagent, node_exporter.
# These are baked into the base image so every node can ship metrics/logs
# to the platform-wide VictoriaMetrics + VictoriaLogs stack at
# victoria-storage.local.genesis-core.tech (private DNS).
#
# vmagent:       scrapes node_exporter, relays metrics to VictoriaMetrics
# vlagent:       receives syslog on localhost:9514 (TCP) and journald on
#                localhost:9429 (HTTP /insert/journald), relays logs to VictoriaLogs
# rsyslog:       forwards all syslog messages to vlagent on localhost:9514
# journal-upload: forwards journald logs to vlagent on localhost:9429
# node_exporter: exposes node-level HW/OS metrics on 127.0.0.1:9100
#
# vmagent and vlagent use ExecStartPre to wait for the observability DNS
# record to resolve before starting. If the observability element is not
# deployed, the services stay dormant but enabled.

VM_VERSION="v1.131.0"
VL_VERSION="v1.51.0"
NE_VERSION="1.10.0"

OBS_CFG_DIR=/etc/exordos_observability
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- vmagent ---
curl -fsSL -o "$TMP_DIR/vmutils.tar.gz" \
    "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/vmutils-linux-amd64-${VM_VERSION}.tar.gz"
tar -xzf "$TMP_DIR/vmutils.tar.gz" -C "$TMP_DIR"
sudo cp "$TMP_DIR/vmagent-prod" /usr/bin/vmagent
sudo chmod +x /usr/bin/vmagent

# --- vlagent ---
curl -fsSL -o "$TMP_DIR/vlutils.tar.gz" \
    "https://github.com/VictoriaMetrics/VictoriaLogs/releases/download/${VL_VERSION}/vlutils-linux-amd64-${VL_VERSION}.tar.gz"
tar -xzf "$TMP_DIR/vlutils.tar.gz" -C "$TMP_DIR"
sudo cp "$TMP_DIR/vlagent-prod" /usr/bin/vlagent
sudo chmod +x /usr/bin/vlagent

# --- node_exporter ---
curl -fsSL -o "$TMP_DIR/node_exporter.tar.gz" \
    "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
tar -xzf "$TMP_DIR/node_exporter.tar.gz" -C "$TMP_DIR"
sudo cp "$TMP_DIR/node_exporter-${NE_VERSION}.linux-amd64/node_exporter" /usr/bin/node_exporter
sudo chmod +x /usr/bin/node_exporter

# Install observability agent config, DNS wait script, and systemd services
sudo mkdir -p "$OBS_CFG_DIR"
sudo cp "$IMG_ARTS_PATH/etc/exordos_observability/vmagent_scrape.yml.tpl" "$OBS_CFG_DIR/"
sudo cp "$IMG_ARTS_PATH/etc/exordos_observability/observability.conf" "$OBS_CFG_DIR/"
sudo cp "$IMG_ARTS_PATH/etc/exordos_observability/exordos-observability-wait-dns.sh" "/usr/local/lib/exordos/"
sudo chmod +x "/usr/local/lib/exordos/exordos-observability-wait-dns.sh"

sudo cp "$IMG_ARTS_PATH/etc/systemd/exordos-node-exporter.service" $SYSTEMD_SERVICE_DIR
sudo cp "$IMG_ARTS_PATH/etc/systemd/exordos-vmagent.service" $SYSTEMD_SERVICE_DIR
sudo cp "$IMG_ARTS_PATH/etc/systemd/exordos-vlagent.service" $SYSTEMD_SERVICE_DIR

# Install rsyslog forwarding config (syslog -> vlagent on localhost:9514)
sudo cp "$IMG_ARTS_PATH/etc/rsyslog.d/49-exordos-vlagent.conf" /etc/rsyslog.d/

# Install systemd-journal-upload config (journald -> vlagent on localhost:9429)
# and a drop-in so journal-upload starts after vlagent is ready.
sudo cp "$IMG_ARTS_PATH/etc/systemd/journal-upload.conf" /etc/systemd/
sudo mkdir -p /etc/systemd/system/systemd-journal-upload.service.d
sudo cp "$IMG_ARTS_PATH/etc/systemd/systemd-journal-upload.service.d/exordos-vlagent.conf" \
    /etc/systemd/system/systemd-journal-upload.service.d/

sudo systemctl enable exordos-node-exporter exordos-vmagent exordos-vlagent
sudo systemctl enable rsyslog systemd-journal-upload

# Set default password
cat > /tmp/__passwd <<EOF
ubuntu:$PASSWD
EOF

sudo chpasswd < /tmp/__passwd
rm -f /tmp/__passwd

# Cleanup
# remove old kernels, headers and modules, keep only the latest one
LATEST_KERNEL_PKG=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | grep '^ii' | awk '{print $2}' | sort -V | tail -n 1 || true)
if [ -n "$LATEST_KERNEL_PKG" ]; then
    VERSION=$(echo "$LATEST_KERNEL_PKG" | sed 's/linux-image-//' | sed 's/-generic$//')
    OLD_PKGS=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' 2>/dev/null | grep '^ii' | awk '{print $2}' | grep -v "$VERSION" || true)
    if [ -n "$OLD_PKGS" ]; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get autopurge -y $OLD_PKGS
    fi
fi

sudo apt autopurge -y snapd libllvm19 python3-botocore python-babel-localedata python3-twisted
sudo rm -fr /opt/eci_base
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /tmp/*
fstrim -v /
