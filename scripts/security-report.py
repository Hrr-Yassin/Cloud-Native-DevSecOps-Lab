#!/usr/bin/env python3
"""Create the publishable workflow summary from explicitly selected gate results."""

import json
import os
from collections import Counter
from pathlib import Path

REPORTS = Path(".reports")
GATES = ("source", "tests", "semgrep", "gitleaks", "dependencies", "iac", "image_build",
         "image_security", "cluster")
SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")


def load(name):
    path = REPORTS / name
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None


def main():
    states = {gate: os.getenv("GATE_" + gate.upper()) or "skipped" for gate in GATES}
    reports = {
        "image": ("image-vulnerabilities.json", "Vulnerabilities"),
        "iac": ("iac.json", "Misconfigurations"),
    }
    findings = {}
    for source, (name, field) in reports.items():
        data = load(name)
        if data is None:
            continue
        values = Counter(str(v.get("Severity", "UNKNOWN")).upper()
                         for target in data.get("Results") or []
                         for v in target.get(field) or [])
        findings[source] = {severity.lower(): values[severity] for severity in SEVERITIES}
    summary = {
        "schema": 1,
        "run_id": int(os.getenv("GITHUB_RUN_ID", "0")),
        "status": "success" if all(state == "success" for state in states.values()) else "failure",
        "gates": states,
        "findings": findings,
    }
    REPORTS.mkdir(exist_ok=True)
    (REPORTS / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    output = os.getenv("GITHUB_STEP_SUMMARY")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("## Security gates\n\n| Gate | Outcome |\n| --- | --- |\n")
            for name, state in states.items():
                handle.write(f"| {name} | {state} |\n")
            if findings:
                handle.write("\n| Scanner | Critical | High | Medium | Low | Unknown |\n")
                handle.write("| --- | --- | --- | --- | --- | --- |\n")
                for source, counts in findings.items():
                    handle.write(f"| {source} | " + " | ".join(map(str, counts.values())) + " |\n")


if __name__ == "__main__":
    main()
