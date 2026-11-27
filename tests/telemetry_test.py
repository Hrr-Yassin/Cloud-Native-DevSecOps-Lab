import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pipeline_metrics", ROOT / "scripts/pipeline-metrics.py")
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


class TelemetryTest(unittest.TestCase):
    def report(self):
        return {"schema": 1, "run_id": 23, "status": "success",
                "gates": dict.fromkeys(metrics.GATES, "success"),
                "findings": {"image": dict.fromkeys(metrics.LEVELS, 0)}}

    def test_valid_snapshot_has_bounded_labels_and_signed_evidence(self):
        report = self.report()
        report["findings"]["image"]["medium"] = 2
        release = {"run_id": 23, "image": "ghcr.io/example/lab@sha256:" + "a" * 64,
                   "signed": True, "sbom_attested": True}
        output = metrics.render(report, release)
        self.assertIn("lab_ci_run_success 1\n", output)
        self.assertIn('lab_ci_findings{scanner="image",severity="medium"} 2\n', output)
        self.assertIn("lab_ci_sbom_attested 1\n", output)
        self.assertNotIn(release["image"], output)

    def test_mismatched_or_malformed_reports_are_rejected(self):
        report = self.report()
        release = {"run_id": 24, "image": "ghcr.io/example/lab@sha256:" + "a" * 64,
                   "signed": True, "sbom_attested": True}
        with self.assertRaises(ValueError):
            metrics.render(report, release)
        report["gates"]["source"] = "failure"
        with self.assertRaises(ValueError):
            metrics.render(report, None)
        report["status"] = "failure"
        self.assertIn("lab_ci_run_success 0\n", metrics.render(report, None))
        report["findings"]["other\nmetric"] = report["findings"]["image"]
        with self.assertRaises(ValueError):
            metrics.render(report, None)

    def test_local_snapshot_validates_archive_identity_and_omits_github_run(self):
        archive = "a" * 64
        deployment = {
            "archive_sha256": archive,
            "compliant": {"exit_code": 0, "cluster_deleted": True},
            "noncompliant": {"exit_code": 1, "cluster_deleted": True, "admission_policy": "desk-pod-controls",
                             "reason": "read-only container root filesystem required"},
        }
        scan = {"sha256": archive, "scanned_archive_matches_deployment_input": True, "blocking_findings": 0,
                "sbom": {"format": "CycloneDX", "components": 1},
                "findings_by_severity": dict.fromkeys(metrics.LEVELS, 0)}
        output = metrics.render_local(deployment, scan)
        self.assertIn("lab_ci_run_success 1\n", output)
        self.assertIn("lab_ci_sbom_generated 1\n", output)
        self.assertNotIn("lab_ci_run_id", output)
        self.assertNotIn("lab_ci_release_signed", output)
        deployment["noncompliant"]["exit_code"] = 0
        self.assertIn("lab_ci_run_success 0\n", metrics.render_local(deployment, scan))
        scan["sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "different archives"):
            metrics.render_local(deployment, scan)

    def export(self, source, *events):
        lines = "\n".join(json.dumps(item) for item in events) + "\nmalformed\n"
        result = subprocess.run([sys.executable, "scripts/export-soc-events.py", "--source", source],
                                cwd=ROOT, input=lines, text=True, check=True, capture_output=True)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_soc_export_emits_only_public_fields_and_selected_events(self):
        base = {"component": "security-desk", "time": "2026-01-01T00:00:00Z",
                "event": "login_denied", "username": "synthetic-private", "actor_id": 9000}
        exported = self.export("desk", base, {**base, "event": "http_request"})
        self.assertEqual(exported, [{
            "lab_schema": "cloud-devsecops.v1", "source": "desk", "event": "login_denied",
            "severity": "warning", "timestamp": "2026-01-01T00:00:00+00:00",
        }])

    def test_soc_export_maps_runtime_and_admission_without_identifiers(self):
        runtime = {"priority": "Warning", "rule": "DevSecOps Lab Runtime Marker",
                   "time": "2026-01-01T00:00:00Z", "hostname": "synthetic-host"}
        audit = {"responseStatus": {"code": 403}, "stageTimestamp": "2026-01-01T00:00:00Z",
                 "annotations": {"validation.policy.admission.k8s.io/validation_failure": "desk-pod-controls"},
                 "user": {"username": "synthetic-user"}}
        self.assertEqual(self.export("falco", runtime, {**runtime, "priority": "Info"}), [{
            "lab_schema": "cloud-devsecops.v1", "source": "falco", "event": "runtime_fixture",
            "severity": "warning", "timestamp": "2026-01-01T00:00:00+00:00",
        }])
        self.assertEqual(self.export("audit", audit, {**audit, "responseStatus": {"code": 200}}), [{
            "lab_schema": "cloud-devsecops.v1", "source": "audit", "event": "admission_denied",
            "severity": "warning", "timestamp": "2026-01-01T00:00:00+00:00",
        }])


if __name__ == "__main__":
    unittest.main()
