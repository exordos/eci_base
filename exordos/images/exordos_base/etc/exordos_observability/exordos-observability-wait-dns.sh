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

# Blocks until the observability backend DNS record resolves.
# Used as ExecStartPre by exordos-vmagent and exordos-vlagent so they
# only start when the observability element is actually deployed.

OBS_CONF="/etc/exordos_observability/observability.conf"
OBS_HOST="victoria-storage.local.genesis-core.tech"

# Source the config file to pick up a custom OBS_HOST, if any.
if [ -f "$OBS_CONF" ]; then
    # shellcheck source=/dev/null
    . "$OBS_CONF"
fi

while true; do
    if getent hosts "$OBS_HOST" >/dev/null 2>&1; then
        break
    fi
    sleep 60
done

# Give the node agent some time to set the proper hostname once
# DNS starts resolving, so downstream ExecStartPre steps that rely on
# `hostname` (e.g. vmagent_scrape.yml templating) pick up the right value.
sleep 60
exit 0
