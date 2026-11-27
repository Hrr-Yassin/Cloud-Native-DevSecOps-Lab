import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RuntimeEvidenceTests(unittest.TestCase):
    def shell_check(self, command, argument, payload):
        return subprocess.run(
            ["bash", "-c", 'source scripts/runtime-check.sh; ' + command + ' "$1"',
             "runtime-check", str(argument)],
            cwd=ROOT, input=payload, text=True, capture_output=True, check=False,
        )

    def test_fixture_records_keep_only_current_marker_and_rule(self):
        marker = "/tmp/devsecops-lab-runtime-marker-0123456789abcdef"
        matching = {
            "rule": "DevSecOps Lab Runtime Marker", "priority": "Warning",
            "output_fields": {"fd.name": marker},
        }
        feed = [
            {**matching, "output_fields": {"fd.name": marker + "-other"}},
            {**matching, "rule": "Unrelated Falco alert"},
            ["malformed", "shape"],
            matching,
        ]
        payload = "non-JSON log text\n" + "\n".join(map(json.dumps, feed)) + "\n"
        result = self.shell_check("fixture_records", marker, payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()], [matching])

    def test_alertmanager_evidence_needs_a_fresh_active_fixture_alert(self):
        threshold = int(datetime(2026, 1, 1, 12, 0, 0, 500000, tzinfo=timezone.utc).timestamp() * 1000)
        matching = {
            "labels": {"alertname": "LabRuntimeFixtureObserved"},
            "status": {"state": "active"},
            "startsAt": "2026-01-01T12:00:01.125+00:00",
        }
        unrelated = [
            {**matching, "labels": {"alertname": "LabRuntimeAlertObserved"}},
            {**matching, "startsAt": "2026-01-01T12:00:00.499Z"},
            {**matching, "status": {"state": "suppressed"}},
            {**matching, "startsAt": "invalid"},
        ]
        rejected = self.shell_check("current_fixture_alert", threshold, json.dumps(unrelated))
        accepted = self.shell_check(
            "current_fixture_alert", threshold, json.dumps([*unrelated, matching]),
        )
        self.assertEqual(rejected.returncode, 1, rejected.stderr)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)


class PipelineMetricImportTests(unittest.TestCase):
    def test_rejects_partial_documents_and_boolean_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            for payload in (b'{"schema":1}' + b' ' * 70000, b'{"schema":true}'):
                with self.subTest(size=len(payload)):
                    report.write_bytes(payload)
                    result = subprocess.run(
                        [sys.executable, "scripts/pipeline-metrics.py", "--report", str(report)],
                        cwd=ROOT, capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, "Invalid report (ValueError).\n")


if __name__ == "__main__":
    unittest.main()
