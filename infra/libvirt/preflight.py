"""Check libvirt ownership from the lab's local state before changing resources."""

import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

NAME = "devsecops-lab"
POOL_PATH = Path("/var/lib/libvirt/images") / NAME
PROFILES = {"primary": NAME, "acceptance": "devsecops-lab-check"}
VOLUME_NAMES = {
    ("libvirt_volume", "base"): "noble-base.qcow2",
    ("libvirt_volume", "root"): "lab-root.qcow2",
    ("libvirt_cloudinit_disk", "lab"): "lab-seed.iso",
}
OBJECTS = (
    ("domain", "list", "domuuid"),
    ("network", "net-list", "net-uuid"),
    ("pool", "pool-list", "pool-uuid"),
)


def state_ids(path, profile="primary"):
    name = PROFILES[profile]
    pool_path = POOL_PATH.with_name(name)
    try:
        with path.open(encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return {}
    if state["version"] != 4:
        raise ValueError("The OpenTofu state format is unexpected")
    object_names = {(f"libvirt_{kind}", "lab"): name for kind, *_ in OBJECTS}
    expected = object_names | VOLUME_NAMES
    ids = {}
    for resource in state["resources"]:
        address = (resource["type"], resource["name"])
        if resource["mode"] != "managed" or resource.get("module") or address not in expected:
            raise ValueError("The OpenTofu state includes an unexpected resource")
        for instance in resource["instances"]:
            attributes = instance["attributes"]
            if address in ids or attributes["name"] != expected[address] or not attributes["id"]:
                raise ValueError("The OpenTofu state includes an unexpected resource instance")
            if address in VOLUME_NAMES:
                key = attributes["id"].partition(";")[0]
                if attributes["pool"] != name or Path(key) != pool_path / expected[address]:
                    raise ValueError("The OpenTofu state references a volume outside the lab pool")
            ids[address] = attributes["id"]
    return ids


def virsh(*args):
    return subprocess.run(
        ["virsh", "--readonly", "--connect", "qemu:///system", *args],
        check=True, capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"},
    ).stdout.strip()


def verify(ids, action, profile="primary"):
    name = PROFILES[profile]
    pool_path = POOL_PATH.with_name(name)
    if pool_path.is_symlink():
        raise ValueError("The lab storage path is a symbolic link")
    owned = set()
    for kind, list_command, uuid_command in OBJECTS:
        names = virsh(list_command, "--all", "--name").splitlines()
        if name in names:
            if virsh(uuid_command, name) != ids.get((f"libvirt_{kind}", "lab")):
                raise ValueError(f"The dedicated {kind} name belongs to an unmanaged object")
            owned.add(kind)
        if kind == "pool":
            for pool_name in names:
                path = ET.fromstring(virsh("pool-dumpxml", pool_name)).findtext("target/path")
                if pool_name == name and (not path or Path(path) != pool_path):
                    raise ValueError("The dedicated pool target path differs from the lab path")
                if pool_name != name and path and Path(path).resolve() == pool_path.resolve():
                    raise ValueError("Another libvirt pool uses the lab storage path")

    if "pool" in owned:
        expected_volumes = {
            volume_name: ids[address].partition(";")[0]
            for address, volume_name in VOLUME_NAMES.items() if address in ids
        }
        # The first two lines are the headings and separator, in the C locale.
        for entry in virsh("vol-list", name).splitlines()[2:]:
            if entry.strip():
                volume_name, *_ = entry.split()
                if (volume_name not in expected_volumes
                        or virsh("vol-key", volume_name, "--pool", name) != expected_volumes[volume_name]):
                    raise ValueError("The lab pool contains an unmanaged storage volume")
    elif action == "up":
        try:
            pool_path.lstat()
        except FileNotFoundError:
            pass
        else:
            raise ValueError("The lab storage path already exists outside the dedicated pool")
    if action == "configure" and owned != {kind for kind, *_ in OBJECTS}:
        raise ValueError("The dedicated VM, network, and storage pool are required for configuration")
    return "owned" if owned else "absent"


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4) or sys.argv[2] not in {"up", "configure", "destroy"}:
        raise SystemExit("Usage: preflight.py <state> <up|configure|destroy> [primary|acceptance]")
    try:
        profile = sys.argv[3] if len(sys.argv) == 4 else "primary"
        print(verify(state_ids(Path(sys.argv[1]), profile), sys.argv[2], profile))
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            raise SystemExit(f"Libvirt read-only check failed ({error.cmd[4]} returned {error.returncode})")
        raise SystemExit(f"Libvirt ownership check failed: {error}")
