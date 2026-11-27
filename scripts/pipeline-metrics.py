#!/usr/bin/env python3
"""Render or import a sanitized CI snapshot to the local lab Pushgateway."""

import argparse
import http.client
import json
import re
from pathlib import Path

GATES = ("source", "tests", "semgrep", "gitleaks", "dependencies", "iac",
         "image_build", "image_security", "cluster")
STATES = {"success": 1, "failure": 0, "cancelled": -1, "skipped": -1}
LEVELS = ("critical", "high", "medium", "low", "unknown")
MAX_REPORT_BYTES = 65536


def object_from(path, *, schema_required=True):
    with path.open("rb") as data:
        payload = data.read(MAX_REPORT_BYTES + 1)
    if len(payload) > MAX_REPORT_BYTES:
        raise ValueError("Report exceeds the size limit")
    model = json.loads(payload.decode("utf-8"))
    if not isinstance(model, dict) or (schema_required and
            (type(model.get("schema")) is not int or model["schema"] != 1)):
        raise ValueError("Unsupported report schema")
    return model


def finding_series(findings):
    if not isinstance(findings, dict):
        raise ValueError("Unsupported scanner findings")
    for scanner, counts in findings.items():
        if scanner not in ("image", "iac") or not isinstance(counts, dict) or set(counts) != set(LEVELS):
            raise ValueError("Unsupported scanner or severity labels")
        for level in LEVELS:
            value = counts[level]
            if type(value) is not int or not 0 <= value <= 100000:
                raise ValueError("Invalid finding count")
            yield f'lab_ci_findings{{scanner="{scanner}",severity="{level}"}} {value}'


def render(report, release):
    run = report.get("run_id")
    if type(run) is not int or run < 1:
        raise ValueError("A positive workflow run ID is required")
    gates = report["gates"]
    if (not isinstance(gates, dict) or set(gates) != set(GATES)
            or any(not isinstance(state, str) or state not in STATES for state in gates.values())):
        raise ValueError("Unexpected CI gate vocabulary")
    status = "success" if all(gates[name] == "success" for name in GATES) else "failure"
    if status != report["status"]:
        raise ValueError("Inconsistent CI gate outcomes")
    lines = [f"lab_ci_run_success {STATES[status]}", f"lab_ci_run_id {run}"]
    for name in GATES:
        lines.append(f'lab_ci_stage_success{{gate="{name}"}} {STATES[gates[name]]}')
    if gates["image_security"] in ("success", "failure"):
        lines.append(f'lab_ci_image_scan_pass {STATES[gates["image_security"]]}')
    lines.extend(finding_series(report["findings"]))
    if release is not None:
        image = release.get("image", "")
        if (type(release.get("run_id")) is not int or release["run_id"] != run
                or status != "success" or release.get("signed") is not True
                or release.get("sbom_attested") is not True or not isinstance(image, str)
                or not re.fullmatch(r"ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+@sha256:[a-f0-9]{64}", image)):
            raise ValueError("The signed artifact evidence differs from the CI snapshot")
        lines.extend(("lab_ci_release_signed 1", "lab_ci_sbom_attested 1"))
    return "\n".join(lines) + "\n"


def render_local(deployment, scan):
    archive = deployment["archive_sha256"]
    if (not isinstance(archive, str) or not re.fullmatch(r"[a-f0-9]{64}", archive)
            or scan.get("sha256") != archive or scan.get("scanned_archive_matches_deployment_input") is not True):
        raise ValueError("The local scan and deployment used different archives")
    compliant, noncompliant = deployment["compliant"], deployment["noncompliant"]
    if (type(compliant["exit_code"]) is not int or type(noncompliant["exit_code"]) is not int
            or type(scan["blocking_findings"]) is not int or scan["blocking_findings"] < 0):
        raise ValueError("Invalid local gate outcome")
    cluster_passed = (compliant["exit_code"] == 0 and noncompliant["exit_code"] == 1
                      and noncompliant.get("admission_policy") == "desk-pod-controls"
                      and noncompliant.get("reason") == "read-only container root filesystem required"
                      and compliant.get("cluster_deleted") is True and noncompliant.get("cluster_deleted") is True)
    sbom = scan["sbom"]
    sbom_generated = (sbom.get("format") == "CycloneDX" and type(sbom.get("components")) is int
                      and sbom["components"] > 0)
    scan_passed = scan["blocking_findings"] == 0 and sbom_generated
    lines = [
        f"lab_ci_run_success {int(cluster_passed and scan_passed)}",
        f'lab_ci_stage_success{{gate="cluster"}} {int(cluster_passed)}',
        f'lab_ci_stage_success{{gate="image_security"}} {int(scan_passed)}',
        f"lab_ci_image_scan_pass {int(scan_passed)}",
        f"lab_ci_sbom_generated {int(sbom_generated)}",
        *finding_series({"image": scan["findings_by_severity"]}),
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--report", type=Path)
    inputs.add_argument("--local-deployment", type=Path)
    parser.add_argument("--release", type=Path)
    parser.add_argument("--local-scan", type=Path)
    parser.add_argument("--push", action="store_true")
    args = parser.parse_args()
    path = "/metrics/job/devsecops_ci"
    try:
        if args.local_deployment:
            if not args.local_scan or args.release:
                parser.error("Local deployment evidence requires its matching local scan.")
            metrics = render_local(object_from(args.local_deployment, schema_required=False),
                                   object_from(args.local_scan, schema_required=False))
            path += "/scope/local"
        else:
            if args.local_scan:
                parser.error("Select local deployment evidence for a local scan.")
            metrics = render(object_from(args.report), object_from(args.release) if args.release else None)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        parser.exit(1, f"Invalid report ({type(exc).__name__}).\n")
    if not args.push:
        print(metrics, end="")
        return
    connection = http.client.HTTPConnection("127.0.0.1", 19091, timeout=6)
    try:
        connection.request("PUT", path, body=metrics,
                           headers={"Content-Type": "text/plain; version=0.0.4"})
        with connection.getresponse() as response:
            if response.status not in (200, 202):
                parser.exit(1, f"Pushgateway returned HTTP {response.status}.\n")
    finally:
        connection.close()
    print("The CI snapshot was imported.")


if __name__ == "__main__":
    main()
