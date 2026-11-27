#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/vm-profile.sh
data="$lab_data"
if [[ "$lab_profile" == acceptance ]]; then
  export TF_DATA_DIR="$data/tofu"
  existing_state="$data/terraform.tfstate"
else
  export TF_DATA_DIR="$PWD/infra/libvirt/.terraform"
  existing_state="$PWD/infra/libvirt/terraform.tfstate"
fi
guest_network="${LAB_GUEST_NETWORK:-$lab_default_cidr}"
cloud_url=https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img
cloud_hash=04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94
export TF_VAR_profile="$lab_profile"

lock_vm() {
  mkdir -p "$data"
  exec 9>"$data/vm.lock"
  if ! flock -n 9; then
    printf 'Another operation is using the dedicated VM.\n' >&2
    exit 1
  fi
  export TF_WORKSPACE=default
}

case "${1:-}" in
  up)
    for tool in tofu virsh curl ssh-keygen ip python3 flock mkisofs sha256sum; do
      if ! command -v "$tool" >/dev/null; then
        printf 'The dedicated VM requires %s on the host.\n' "$tool" >&2
        exit 1
      fi
    done
    lock_vm
    ownership=$(python3 infra/libvirt/preflight.py "$existing_state" up "$lab_profile")
    if [[ "$ownership" == absent ]]; then
      if ip link show dev "$lab_bridge" >/dev/null 2>&1; then
        printf 'The dedicated bridge name is already in use.\n' >&2
        exit 1
      fi
      ip -j -4 route show table all | python3 -c '
import ipaddress, json, sys
requested = ipaddress.ip_network(sys.argv[1])
for route in json.load(sys.stdin):
    destination = route.get("dst", "default")
    if destination != "default" and requested.overlaps(ipaddress.ip_network(destination, strict=False)):
        raise SystemExit("The requested lab subnet overlaps an existing route.")
' "$guest_network"
    else
      saved_network=$(tofu -chdir=infra/libvirt output -state="$existing_state" -raw guest_network 2>/dev/null || true)
      if [[ -n "$saved_network" && "$saved_network" != "$guest_network" ]]; then
        printf 'Use the existing lab subnet until this VM is destroyed.\n' >&2
        exit 1
      fi
    fi
    if [[ ! -s "$data/ssh" ]]; then
      ssh-keygen -q -t ed25519 -N '' -C "$lab_instance" -f "$data/ssh"
    fi
    export TF_VAR_cloud_image="$PWD/.lab/ubuntu-24.04-20261017.img"
    export TF_VAR_cloud_image_sha256="$cloud_hash"
    export TF_VAR_ssh_public_key
    TF_VAR_ssh_public_key=$(awk '{print $1 " " $2}' "$data/ssh.pub")
    export TF_VAR_guest_network="$guest_network"
    if [[ ! -s "$TF_VAR_cloud_image" ]]; then
      asset=$(mktemp "$PWD/.lab/cloud-image.XXXXXX")
      trap 'rm -f -- "$asset"' EXIT
      curl --fail --silent --show-error --location --retry 3 --max-time 900 --proto '=https' --proto-redir '=https' "$cloud_url" -o "$asset"
      printf '%s  %s\n' "$cloud_hash" "$asset" | sha256sum --check --status
      mv -- "$asset" "$TF_VAR_cloud_image"
    fi
    tofu -chdir=infra/libvirt init -input=false
    tofu -chdir=infra/libvirt validate
    tofu -chdir=infra/libvirt apply -state="$existing_state" -input=false -auto-approve
    ip_address=$(tofu -chdir=infra/libvirt output -state="$existing_state" -raw guest_ip)
    inventory=$(python3 - "$ip_address" "$data" "$guest_network" "$lab_instance" <<'INVENTORY'
import ipaddress, json, shlex, sys
address, directory, cidr, instance = sys.argv[1:]
network = ipaddress.ip_network(cidr)
ip = ipaddress.ip_address(address)
if ip not in network or ip in (network.network_address, network.broadcast_address, network.network_address + 1):
    raise SystemExit("The VM did not receive a usable lease in the dedicated network.")
host = {
    "ansible_host": address, "ansible_user": "labops",
    "lab_expected_instance": instance,
    "ansible_ssh_private_key_file": f"{directory}/ssh",
    "ansible_ssh_common_args": shlex.join([
        "-F", f"{directory}/ssh.conf", "-o", f"UserKnownHostsFile={directory}/known_hosts",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "StrictHostKeyChecking=accept-new", "-o", "IdentitiesOnly=yes",
        "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
    ]),
}
print(json.dumps({"all": {"hosts": {"devsecops-lab": host}}}, indent=2))
INVENTORY
)
    printf '%s\n' "$inventory" > "$data/inventory.json"
    cat > "$data/ssh.conf" <<SSH
Host $lab_instance
    HostName $ip_address
    User labops
    IdentityFile "$data/ssh"
    IdentitiesOnly yes
    UserKnownHostsFile "$data/known_hosts"
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
    ConnectTimeout 10
    ServerAliveInterval 10
    ServerAliveCountMax 2
SSH
    ;;
  configure)
    lock_vm
    python3 infra/libvirt/preflight.py "$existing_state" configure "$lab_profile" >/dev/null
    ansible-playbook -i "$data/inventory.json" infra/ansible/site.yml
    tmp=$(mktemp "$data/kubeconfig.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    ssh -F "$data/ssh.conf" "$lab_instance" 'sudo cat /etc/rancher/k3s/k3s.yaml' |
      sed "s#https://127\\.0\\.0\\.1:6443#https://127.0.0.1:$lab_api_port#" > "$tmp"
    KUBECONFIG="$tmp" kubectl config rename-context default "$lab_instance"
    endpoint=$(KUBECONFIG="$tmp" kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}')
    if [[ "$endpoint" != "https://127.0.0.1:$lab_api_port" ]]; then
      printf 'The lab kubeconfig does not target the dedicated tunnel.\n' >&2
      exit 1
    fi
    mv -- "$tmp" "$data/admin.kubeconfig"
    ;;
  tunnel)
    exec ssh -F "$data/ssh.conf" -o ExitOnForwardFailure=yes -N \
      -L "127.0.0.1:$lab_api_port:127.0.0.1:6443" "$lab_instance"
    ;;
  destroy)
    [[ -s "$existing_state" ]]
    lock_vm
    python3 infra/libvirt/preflight.py "$existing_state" destroy "$lab_profile" >/dev/null
    export TF_VAR_cloud_image="$PWD/.lab/ubuntu-24.04-20261017.img"
    export TF_VAR_cloud_image_sha256="$cloud_hash"
    export TF_VAR_ssh_public_key TF_VAR_guest_network="$guest_network"
    TF_VAR_ssh_public_key=$(awk '{print $1 " " $2}' "$data/ssh.pub")
    tofu -chdir=infra/libvirt destroy -state="$existing_state" -input=false -auto-approve
    rm -f -- "$data/known_hosts" "$data/inventory.json" "$data/ssh.conf" "$data/admin.kubeconfig"
    ;;
  *)
    printf 'Usage: %s {up|configure|tunnel|destroy}\n' "$0" >&2
    exit 64
    ;;
esac
