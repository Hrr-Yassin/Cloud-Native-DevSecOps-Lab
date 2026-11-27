import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "infra" / "libvirt"))
import preflight


class LibvirtPreflightTest(unittest.TestCase):
    def setUp(self):
        temporary = self.enterContext(TemporaryDirectory())
        self.path = Path(temporary) / preflight.NAME
        self.state = Path(temporary) / "terraform.tfstate"
        self.enterContext(patch.object(preflight, "POOL_PATH", self.path))
        self.names = {
            ("list", "--all", "--name"): "other-vm",
            ("net-list", "--all", "--name"): "other-network",
            ("pool-list", "--all", "--name"): "other-pool",
            ("pool-dumpxml", "other-pool"): "<pool><target><path>/var/lib/libvirt/other</path></target></pool>",
        }
        self.enterContext(patch.object(preflight, "virsh", side_effect=lambda *args: self.names[args]))

    def register_owned_objects(self):
        ids = {}
        for index, (kind, list_command, uuid_command) in enumerate(preflight.OBJECTS):
            uuid = f"00000000-0000-0000-0000-{index + 1:012d}"
            self.names[(list_command, "--all", "--name")] += "\n" + preflight.NAME
            self.names[(uuid_command, preflight.NAME)] = uuid
            ids[(f"libvirt_{kind}", "lab")] = uuid
        self.names[("pool-dumpxml", preflight.NAME)] = f"<pool><target><path>{self.path}</path></target></pool>"
        self.names[("vol-list", preflight.NAME)] = " Name       Path\n------------------"
        return ids

    def test_empty_lab_state_leaves_unrelated_objects_out_of_scope(self):
        self.assertEqual(preflight.state_ids(self.state), {})
        self.assertEqual(preflight.verify({}, "up"), "absent")
        with self.assertRaisesRegex(ValueError, "required for configuration"):
            preflight.verify({}, "configure")

    def test_previous_state_address_does_not_authorize_a_replaced_domain(self):
        ids = self.register_owned_objects()
        self.names[("domuuid", preflight.NAME)] = "00000000-0000-0000-0000-000000000004"
        with self.assertRaisesRegex(ValueError, "domain name belongs to an unmanaged object"):
            preflight.verify(ids, "destroy")

    def test_pool_cannot_overwrite_an_unmanaged_base_image(self):
        ids = self.register_owned_objects()
        key = str(self.path / "noble-base.qcow2")
        self.names[("vol-list", preflight.NAME)] += f"\n noble-base.qcow2 {key}"
        self.names[("vol-key", "noble-base.qcow2", "--pool", preflight.NAME)] = key
        with self.assertRaisesRegex(ValueError, "unmanaged storage volume"):
            preflight.verify(ids, "up")
        resource = {
            "mode": "managed", "type": "libvirt_volume", "name": "base",
            "instances": [{"attributes": {"name": "noble-base.qcow2", "id": key, "pool": preflight.NAME}}],
        }
        self.state.write_text(json.dumps({"version": 4, "resources": [resource]}), encoding="utf-8")
        ids.update(preflight.state_ids(self.state))
        self.assertEqual(preflight.verify(ids, "configure"), "owned")

    def test_unrelated_pool_cannot_claim_the_lab_directory(self):
        self.names[("pool-dumpxml", "other-pool")] = f"<pool><target><path>{self.path}</path></target></pool>"
        with self.assertRaisesRegex(ValueError, "Another libvirt pool uses the lab storage path"):
            preflight.verify({}, "up")

    def test_state_with_other_resources_cannot_authorize_teardown(self):
        resource = {"mode": "managed", "type": "libvirt_domain", "name": "other-vm", "instances": []}
        self.state.write_text(json.dumps({"version": 4, "resources": [resource]}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "state includes an unexpected resource"):
            preflight.state_ids(self.state)


if __name__ == "__main__":
    unittest.main()
