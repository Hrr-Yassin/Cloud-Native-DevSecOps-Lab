#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
existing_state=infra/libvirt/terraform.tfstate
data="$PWD/.lab"
guest_network="${LAB_GUEST_NETWORK:-172.30.88.0/24}"
cloud_url=https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img
cloud_hash=04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94

case "${1:-}" in
  up)
    for tool in tofu virsh curl ssh-keygen ip python3; do command -v "$tool" >/dev/null; done
    virsh --readonly --connect qemu:///system list --all --name >/dev/null
    mkdir -p "$data"
    tracked=$(tofu -chdir=infra/libvirt state list 2>/dev/null || true)
    domains=$(virsh --readonly --connect qemu:///system list --all --name)
    networks=$(virsh --readonly --connect qemu:///system net-list --all --name)
    pools=$(virsh --readonly --connect qemu:///system pool-list --all --name)
    for kind in domain network pool; do
      case "$kind" in
        domain) names="$domains" ;;
        network) names="$networks" ;;
        pool) names="$pools" ;;
      esac
      if grep -Fxq devsecops-lab <<< "$names" && ! grep -Fxq "libvirt_$kind.lab" <<< "$tracked"; then
        printf 'The dedicated %s name is in use outside this OpenTofu state.\n' "$kind" >&2
        exit 1
      fi
    done
    if ! grep -Fxq libvirt_network.lab <<< "$tracked"; then
      if ip link show dev virbr-dslab >/dev/null 2>&1; then
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
      saved_network=$(tofu -chdir=infra/libvirt output -raw guest_network 2>/dev/null || true)
      if [[ -n "$saved_network" && "$saved_network" != "$guest_network" ]]; then
        printf 'Use the existing lab subnet until this VM is destroyed.\n' >&2
        exit 1
      fi
    fi
    if [[ ! -s "$data/ssh" ]]; then
      ssh-keygen -q -t ed25519 -N '' -C devsecops-lab -f "$data/ssh"
    fi
    export TF_VAR_cloud_image="$data/ubuntu-24.04-20261017.img"
    export TF_VAR_cloud_image_sha256="$cloud_hash"
    export TF_VAR_ssh_public_key
    TF_VAR_ssh_public_key=$(awk '{print $1 " " $2}' "$data/ssh.pub")
    export TF_VAR_guest_network="$guest_network"
    if [[ ! -s "$TF_VAR_cloud_image" ]]; then
      asset=$(mktemp "$data/cloud-image.XXXXXX")
      trap 'rm -f -- "$asset"' EXIT
      curl --fail --silent --show-error --location --retry 3 --max-time 900 --proto '=https' --proto-redir '=https' "$cloud_url" -o "$asset"
      printf '%s  %s\n' "$cloud_hash" "$asset" | sha256sum --check --status
      mv -- "$asset" "$TF_VAR_cloud_image"
    fi
    tofu -chdir=infra/libvirt init -input=false
    tofu -chdir=infra/libvirt validate
    tofu -chdir=infra/libvirt apply -input=false -auto-approve
    ip_address=$(tofu -chdir=infra/libvirt output -raw guest_ip)
    python3 -c 'import ipaddress, sys; assert ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2])' "$ip_address" "$guest_network"
    python3 - "$ip_address" "$data" > "$data/inventory.json" <<'INVENTORY'
import json, shlex, sys
address, directory = sys.argv[1:]
host = {
    "ansible_host": address, "ansible_user": "labops",
    "ansible_ssh_private_key_file": f"{directory}/ssh",
    "ansible_ssh_common_args": shlex.join([
        "-o", f"UserKnownHostsFile={directory}/known_hosts",
        "-o", "StrictHostKeyChecking=accept-new", "-o", "IdentitiesOnly=yes",
    ]),
}
print(json.dumps({"all": {"hosts": {"devsecops-lab": host}}}, indent=2))
INVENTORY
    cat > "$data/ssh.conf" <<SSH
Host devsecops-lab
    HostName $ip_address
    User labops
    IdentityFile "$data/ssh"
    IdentitiesOnly yes
    UserKnownHostsFile "$data/known_hosts"
    StrictHostKeyChecking yes
SSH
    ;;
  configure)
    ansible-playbook -i "$data/inventory.json" infra/ansible/site.yml
    tmp=$(mktemp "$data/kubeconfig.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    ssh -F "$data/ssh.conf" devsecops-lab 'sudo cat /etc/rancher/k3s/k3s.yaml' |
      sed 's#https://127\.0\.0\.1:6443#https://127.0.0.1:16443#' > "$tmp"
    KUBECONFIG="$tmp" kubectl config rename-context default devsecops-lab
    mv -- "$tmp" "$data/admin.kubeconfig"
    ;;
  tunnel)
    exec ssh -F "$data/ssh.conf" -o ExitOnForwardFailure=yes -N       -L 127.0.0.1:16443:127.0.0.1:6443 devsecops-lab
    ;;
  destroy)
    [[ -s "$existing_state" ]]
    export TF_VAR_cloud_image="$data/ubuntu-24.04-20261017.img"
    export TF_VAR_cloud_image_sha256="$cloud_hash"
    export TF_VAR_ssh_public_key TF_VAR_guest_network="$guest_network"
    TF_VAR_ssh_public_key=$(awk '{print $1 " " $2}' "$data/ssh.pub")
    tofu -chdir=infra/libvirt destroy -input=false -auto-approve
    rm -f -- "$data/known_hosts" "$data/inventory.json" "$data/ssh.conf" "$data/admin.kubeconfig"
    ;;
  *)
    printf 'Usage: %s {up|configure|tunnel|destroy}\n' "$0" >&2
    exit 64
    ;;
esac
