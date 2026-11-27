#!/usr/bin/env python3
"""Normalize approved JSON log lines to a Wazuh-compatible local NDJSON stream."""

import argparse
import datetime as dt
import json
import sys

LEVELS = {"warning", "error", "critical", "alert", "emergency"}


def event(source, data):
    if source == "desk" and data.get("component") == "security-desk":
        kind = data.get("event")
        if kind in ("login_denied", "request_error", "finding_created", "finding_updated"):
            level = "warning" if kind in ("login_denied", "request_error") else "info"
            return kind, level, data.get("time")
    if source == "falco" and isinstance(data.get("priority"), str):
        level = data["priority"].lower()
        if level in LEVELS:
            kind = "runtime_fixture" if data.get("rule") == "DevSecOps Lab Runtime Marker" else "runtime_alert"
            return kind, level, data.get("time")
    if source == "audit":
        annotations = data.get("annotations") or {}
        status = data.get("responseStatus") or {}
        failure = annotations.get("validation.policy.admission.k8s.io/validation_failure")
        if status.get("code") in (400, 403, 422) and isinstance(failure, str) and "desk-pod-controls" in failure:
            return "admission_denied", "warning", data.get("stageTimestamp")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, choices=("desk", "audit", "falco"))
    args = parser.parse_args()
    for line in sys.stdin:
        if len(line) > 1024 * 1024:
            continue
        try:
            selected = event(args.source, json.loads(line))
            if selected is None:
                continue
            kind, level, stamp = selected
            instant = dt.datetime.fromisoformat(stamp)
            if instant.tzinfo is None:
                continue
        except (AttributeError, TypeError, ValueError):
            continue
        print(json.dumps({"lab_schema": "cloud-devsecops.v1", "source": args.source,
                          "event": kind, "severity": level,
                          "timestamp": instant.astimezone(dt.timezone.utc).isoformat()}))


if __name__ == "__main__":
    main()
