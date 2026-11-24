# Copyright 2026 Genesis Corporation
# Licensed under the Apache License, Version 2.0.

import base64
import hashlib
import json
import os
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, call

import link_driver
import pytest
from gcl_sdk.agents.universal import constants, utils
from gcl_sdk.agents.universal.api import crypto
from gcl_sdk.agents.universal.dm import models
from gcl_sdk.agents.universal.services.agent import UniversalAgentService
from gcl_sdk.common.utils import load_from_entry_point


@pytest.fixture
def guest(tmp_path, monkeypatch):
    node = uuid.uuid4()
    driver = load_from_entry_point(constants.EP_UNIVERSAL_AGENT, "LinkCapabilityDriver")
    monkeypatch.setattr(utils, "system_uuid", lambda: node)
    monkeypatch.setattr(
        link_driver.grp, "getgrnam", lambda _: SimpleNamespace(gr_gid=os.getgid())
    )
    monkeypatch.setattr(link_driver.os, "fchown", lambda *_: None)
    systemctl = Mock()
    systemctl.return_value.returncode = 0
    monkeypatch.setattr(link_driver.subprocess, "run", systemctl)
    config = tmp_path / "listeners.json"
    identity = tmp_path / "identity.pem"
    key_path = tmp_path / "ua.key"
    key, key_b64 = crypto.generate_key_base64()
    key_path.write_text(key_b64)
    monkeypatch.setattr(link_driver, "CONFIG", config)
    monkeypatch.setattr(link_driver, "IDENTITY", identity)
    settings = SimpleNamespace(private_key_path=str(key_path))
    monkeypatch.setattr(
        link_driver,
        "cfg",
        SimpleNamespace(CONF=SimpleNamespace(universal_agent=settings)),
    )

    service = UniversalAgentService(node, Mock(), [], [])
    instance = driver()

    def reconcile(payload):
        collected = models.Payload.empty()
        assert service._cap_driver_iteration(instance, payload, collected) == set(
            payload.capabilities
        )
        return collected.caps_resources()

    initial = {
        "listeners": [
            {
                "role": "outbound",
                "listen": "127.0.0.1:20001",
                "targets": [],
                "peer_ids": ["spiffe://link.test/backend"],
            }
        ]
    }
    resource_id = uuid.uuid5(node, "link")

    def target(pem, *, config=initial, encryption_key=key):
        nonce, nonce_b64 = crypto.generate_nonce_base64()
        ciphertext = crypto.encrypt_chacha20_poly1305(
            encryption_key, pem, nonce, link_driver.IDENTITY_CONTEXT
        )
        revision = hashlib.sha256(pem).hexdigest()
        digest = utils.calculate_hash({**config, "identity_revision": revision})
        resource = models.Resource(
            uuid=resource_id,
            res_uuid=models.Resource.gen_res_uuid(resource_id, "link"),
            kind="link",
            value={
                **config,
                "identity": {
                    "revision": revision,
                    "nonce": nonce_b64,
                    "sealed": base64.b64encode(ciphertext).decode(),
                },
            },
            hash=digest,
            full_hash=digest,
        )
        payload = models.Payload.empty()
        payload.add_caps_resource(resource)
        return payload

    return SimpleNamespace(
        reconcile=reconcile,
        target=target,
        config=config,
        initial=initial,
        identity=identity,
        systemctl=systemctl,
    )


def service_operation(action):
    return call(["systemctl", action, "exordos-link.service"], check=True, timeout=5)


def service_active_check():
    return call(
        ["systemctl", "is-active", "--quiet", "exordos-link.service"],
        check=False,
        timeout=5,
    )


def test_link_lifecycle(guest):
    initial = guest.target(b"initial identity")
    [applied] = guest.reconcile(initial)
    assert applied.hash == initial.caps_resources()[0].hash
    assert set(applied.value) == {"listeners", "identity_revision"}
    assert json.loads(guest.config.read_bytes()) == guest.initial
    assert guest.identity.read_bytes() == b"initial identity"
    assert guest.config.stat().st_mode & 0o777 == 0o640
    assert guest.identity.stat().st_mode & 0o777 == 0o640
    assert guest.systemctl.call_args_list == [service_operation("reload-or-restart")]
    written = guest.config.stat().st_ino

    unchanged = models.Payload.empty()
    assert guest.reconcile(unchanged) == []
    assert guest.systemctl.call_args == service_active_check()
    renewed = guest.target(b"renewed identity")
    [applied] = guest.reconcile(renewed)
    assert applied.hash == renewed.caps_resources()[0].hash
    assert guest.identity.read_bytes() == b"renewed identity"
    assert guest.systemctl.call_args_list == [
        service_operation("reload-or-restart"),
        service_active_check(),
        service_operation("reload-or-restart"),
    ]
    assert guest.config.stat().st_ino == written
    assert guest.reconcile(renewed)[0].hash == applied.hash

    revoked = models.Payload(capabilities={"link": {"resources": []}})
    guest.identity.unlink()
    assert guest.reconcile(revoked) == []
    assert json.loads(guest.config.read_bytes()) == {"listeners": []}
    assert guest.systemctl.call_args == service_operation("try-reload-or-restart")
    assert guest.reconcile(unchanged) == []
    assert guest.systemctl.call_count == 5


def test_reload_retried_without_a_payload_change(guest):
    guest.systemctl.side_effect = TimeoutError
    with pytest.raises(TimeoutError):
        guest.reconcile(guest.target(b"identity"))
    assert json.loads(guest.config.read_bytes()) == guest.initial

    guest.systemctl.side_effect = None
    assert guest.reconcile(models.Payload.empty()) == []
    assert (
        guest.systemctl.call_args_list == [service_operation("reload-or-restart")] * 2
    )


def test_restarts_stopped_link_without_a_payload_change(guest):
    target = guest.target(b"identity")
    guest.reconcile(target)
    guest.systemctl.reset_mock()
    guest.systemctl.return_value.returncode = 3

    assert guest.reconcile(models.Payload.empty()) == []
    assert guest.systemctl.call_args_list == [
        service_active_check(),
        service_operation("start"),
    ]


def test_invalid_identity_preserves_the_current_key_and_applies_policy(guest):
    guest.reconcile(guest.target(b"current identity"))
    policy = {"listeners": [{**guest.initial["listeners"][0], "peer_ids": []}]}
    foreign_key, _ = crypto.generate_key_base64()
    assert (
        guest.reconcile(
            guest.target(b"foreign identity", config=policy, encryption_key=foreign_key)
        )
        == []
    )
    assert guest.identity.read_bytes() == b"current identity"
    assert json.loads(guest.config.read_bytes()) == policy
    assert guest.systemctl.call_args == service_operation("reload-or-restart")
    assert guest.systemctl.call_count == 2


def test_unit_uses_cached_identity():
    unit = Path(__file__).parents[1] / "etc/systemd/exordos-link.service"
    assert "ExecStartPre" not in unit.read_text()
    assert "ConditionPathExists=/var/lib/exordos/link/identity.pem" in unit.read_text()
