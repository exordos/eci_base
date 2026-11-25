# Copyright 2026 Genesis Corporation
# Licensed under the Apache License, Version 2.0.

import base64
import grp
import hashlib
import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path

from gcl_sdk.agents.universal import utils
from gcl_sdk.agents.universal.api import crypto
from gcl_sdk.agents.universal.dm import models
from gcl_sdk.agents.universal.drivers import base, exceptions
from oslo_config import cfg

KIND = "link"
CONFIG = Path("/etc/exordos-link/listeners.json")
IDENTITY = Path("/var/lib/exordos/link/identity.pem")
UNIT = "exordos-link.service"
IDENTITY_CONTEXT = b"exordos-link-identity-v1"


def publish(path, contents, group):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as staging:
        pending = Path(staging.name)
        try:
            staging.write(contents)
            staging.flush()
            os.fchown(staging.fileno(), 0, group)
            os.fchmod(staging.fileno(), 0o640)
            os.fsync(staging.fileno())
            pending.replace(path)
        finally:
            pending.unlink(missing_ok=True)


def identity_revision():
    try:
        return hashlib.sha256(IDENTITY.read_bytes()).hexdigest()
    except FileNotFoundError:
        return ""


class LinkCapabilityDriver(base.AbstractCapabilityDriver):
    def __init__(self):
        self._uuid = uuid.uuid5(utils.system_uuid(), KIND)
        self._group = grp.getgrnam("exordos-link").gr_gid
        # Reapply the saved policy after an agent restart during a reload.
        self._reload_pending = True

    def get_capabilities(self):
        return [KIND]

    def list(self, capability):
        value = self._read_config()
        if not value or not value["listeners"]:
            return []
        value["identity_revision"] = identity_revision()
        digest = utils.calculate_hash(value)
        return [
            models.Resource(
                uuid=self._uuid,
                kind=KIND,
                res_uuid=models.Resource.gen_res_uuid(self._uuid, KIND),
                value=value,
                hash=digest,
                full_hash=digest,
            )
        ]

    def get(self, resource):
        for actual in self.list(KIND):
            if actual == resource:
                return actual
        raise exceptions.ResourceNotFound(resource=resource)

    def create(self, resource):
        return self.update(resource)

    def update(self, resource):
        config = {"listeners": resource.value["listeners"]}
        if self._read_config() != config:
            self._write_config(config)
        identity = resource.value["identity"]
        if identity_revision() != identity["revision"]:
            key_path = Path(cfg.CONF.universal_agent.private_key_path)
            pem = crypto.decrypt_chacha20_poly1305(
                base64.b64decode(key_path.read_bytes()),
                base64.b64decode(identity["nonce"]),
                base64.b64decode(identity["sealed"]),
                IDENTITY_CONTEXT,
            )
            if hashlib.sha256(pem).hexdigest() != identity["revision"]:
                raise ValueError("Received a mismatched Link identity")
            publish(IDENTITY, pem, self._group)
            self._reload_pending = True
        return self.get(resource)

    def delete(self, resource):
        self._write_config({"listeners": []})

    def finalize(self):
        value = self._read_config()
        if value is None:
            return
        enabled = bool(value["listeners"])
        if self._reload_pending:
            action = "reload-or-restart" if enabled else "try-reload-or-restart"
        elif (
            enabled
            and IDENTITY.is_file()
            and subprocess.run(
                ["systemctl", "is-active", "--quiet", UNIT], check=False, timeout=5
            ).returncode
        ):
            action = "start"
        else:
            return
        subprocess.run(["systemctl", action, UNIT], check=True, timeout=5)
        self._reload_pending = False

    def _read_config(self):
        try:
            return json.loads(CONFIG.read_bytes())
        except FileNotFoundError:
            return None

    def _write_config(self, value):
        publish(CONFIG, json.dumps(value).encode(), self._group)
        self._reload_pending = True
