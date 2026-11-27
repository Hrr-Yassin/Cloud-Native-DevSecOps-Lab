from copy import deepcopy
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class UniqueKeysLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        mapping = super().construct_mapping(node, deep)
        if len(mapping) != len(node.value):
            raise ValueError("Duplicate YAML mapping keys")
        return mapping


def documents(relative):
    return list(yaml.load_all((ROOT / relative).read_text(), Loader=UniqueKeysLoader))


class ConfigurationTest(unittest.TestCase):
    def test_repository_yaml_parses_with_unique_mapping_keys(self):
        folders = ("deploy", "infra/ansible", ".github/workflows", "security")
        for folder in folders:
            for path in sorted((ROOT / folder).rglob("*")):
                if path.suffix in (".yaml", ".yml"):
                    with self.subTest(path=path.relative_to(ROOT)):
                        self.assertTrue(documents(path.relative_to(ROOT)))

    def test_admission_fixtures_differ_only_in_the_writable_root(self):
        good = documents("security/fixtures/compliant.yaml")[0]
        bad = documents("security/fixtures/noncompliant.yaml")[0]
        corrected = deepcopy(bad)
        self.assertFalse(corrected["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"])
        corrected["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"] = True
        self.assertEqual(good, corrected)
        scope = documents("deploy/base/namespace.yaml")[0]["metadata"]["labels"]
        binding = documents("deploy/policy/admission.yaml")[1]["spec"]
        self.assertIn("Deny", binding["validationActions"])
        for label, value in binding["matchResources"]["namespaceSelector"]["matchLabels"].items():
            self.assertEqual(scope[label], value)

    def test_ingress_and_monitoring_have_separate_service_ports(self):
        ingress = documents("deploy/base/ingress.yaml")[0]["spec"]
        self.assertEqual(ingress["tls"][0]["hosts"], ["desk.lab.invalid"])
        backend = ingress["rules"][0]["http"]["paths"][0]["backend"]["service"]
        service_ports = {item["metadata"]["name"]: item["spec"]["ports"][0]["name"]
                         for item in documents("deploy/base/workload.yaml") if item["kind"] == "Service"}
        self.assertEqual(backend["port"]["name"], service_ports[backend["name"]])
        self.assertNotEqual(backend["name"], "desk-metrics")
        self.assertEqual(service_ports["desk-metrics"], "metrics")
        _, allowed = documents("deploy/base/network.yaml")
        self.assertEqual([entry["ports"][0]["port"] for entry in allowed["spec"]["ingress"]], [8080, 9091])
        self.assertTrue(all("namespaceSelector" in entry["from"][0]
                            and "podSelector" in entry["from"][0] for entry in allowed["spec"]["ingress"]))


if __name__ == "__main__":
    unittest.main()
