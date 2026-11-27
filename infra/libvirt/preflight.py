"""Check libvirt ownership from the lab's local state before changing resources."""

import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

NAME = "devsecops-lab"
POOL_PATH = Path("/var/lib/libvirt/images") / NAME
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


def state_ids(path):
    try:
        with path.open(encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return {}
    if state["version"] != 4:
        raise ValueError("The OpenTofu state format is unexpected")
    object_names = {(f"libvirt_{kind}", "lab"): NAME for kind, *_ in OBJECTS}
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
                if attributes["pool"] != NAME or Path(key) != POOL_PATH / expected[address]:
                    raise ValueError("The OpenTofu state references a volume outside the lab pool")
            ids[address] = attributes["id"]
    return ids


def virsh(*args):
    return subprocess.run(
        ["virsh", "--readonly", "--connect", "qemu:///system", *args],
        check=True, capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"},
    ).stdout.strip()


def verify(ids, action):
    if POOL_PATH.is_symlink():
        raise ValueError("The lab storage path is a symbolic link")
    owned = set()
    for kind, list_command, uuid_command in OBJECTS:
        names = virsh(list_command, "--all", "--name").splitlines()
        if NAME in names:
            if virsh(uuid_command, NAME) != ids.get((f"libvirt_{kind}", "lab")):
                raise ValueError(f"The dedicated {kind} name belongs to an unmanaged object")
            owned.add(kind)
        if kind == "pool":
            for name in names:
                path = ET.fromstring(virsh("pool-dumpxml", name)).findtext("target/path")
                if name == NAME and (not path or Path(path) != POOL_PATH):
                    raise ValueError("The dedicated pool target path differs from the lab path")
                if name != NAME and path and Path(path).resolve() == POOL_PATH.resolve():
                    raise ValueError("Another libvirt pool uses the lab storage path")

    if "pool" in owned:
        expected_volumes = {
            name: ids[address].partition(";")[0] for address, name in VOLUME_NAMES.items() if address in ids
        }
        # The first two lines are the headings and separator, in the C locale.
        for entry in virsh("vol-list", NAME).splitlines()[2:]:
            if entry.strip():
                name, *_ = entry.split()
                if name not in expected_volumes or virsh("vol-key", name, "--pool", NAME) != expected_volumes[name]:
                    raise ValueError("The lab pool contains an unmanaged storage volume")
    elif action == "up":
        try:
            POOL_PATH.lstat()
        except FileNotFoundError:
            pass
        else:
            raise ValueError("The lab storage path already exists outside the dedicated pool")
    if action == "configure" and owned != {kind for kind, *_ in OBJECTS}:
        raise ValueError("The dedicated VM, network, and storage pool are required for configuration")
    return "owned" if "network" in owned else "absent"


if __name__ == "__main__":
    try:
        print(verify(state_ids(Path(sys.argv[1])), sys.argv[2]))
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            raise SystemExit(f"Libvirt read-only check failed ({error.cmd[4]} returned {error.returncode})")
        raise SystemExit(f"Libvirt ownership check failed: {error}")
