#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/vm-profile.sh
mode=${1:-release}
case "$mode" in release|prepare|deploy) ;; *) printf 'Use release, prepare, or deploy.\n' >&2; exit 64;; esac
if [[ "$mode" != prepare ]]; then
  source scripts/verify-target.sh
  require_lab_context
  [[ "$(kubectl config current-context)" == "$lab_instance" ]]
fi
data="$PWD/.lab/local-release"
image_ref="$data/image.ref"
if [[ "$lab_profile" == acceptance ]]; then
  image_ref="$lab_data/image.ref"
  export LAB_TLS_DIR="${LAB_TLS_DIR:-$lab_data/tls}"
fi
mkdir -p "$data/artifacts"
exec 9>"$data/release.lock"
flock -n 9
tag=localhost/security-desk:local

verify_archive() {
  cosign verify-blob --key "$data/signing.pub" --signature "$1/desk.sig" \
    --insecure-ignore-tlog=true "$1/desk.tar"
}

if [[ "$mode" != deploy ]]; then
  [[ -s "$data/signing.key" && -s "$data/signing.pub" ]] || {
    printf 'Generate the dedicated signing key with cosign generate-key-pair --output-key-prefix .lab/local-release/signing.\n' >&2
    exit 64
  }
  work=$(mktemp -d "$data/build.XXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  podman_opts=(--root "$PWD/.lab/podman/store" --runroot "$PWD/.lab/podman/run" --storage-driver vfs)
  podman "${podman_opts[@]}" build --pull=always --network=none --file Containerfile --tag "$tag" .
  podman "${podman_opts[@]}" save --format oci-dir --output "$work/layout" "$tag"
  scripts/image-gates.sh "$work/layout" .reports
  tar -C "$work/layout" -cf "$work/desk.tar" oci-layout index.json blobs
  rm -rf -- "$work/layout"
  cosign sign-blob --yes --key "$data/signing.key" --new-bundle-format=false --use-signing-config=false \
    --tlog-upload=false --output-signature "$work/desk.sig" "$work/desk.tar"
  verify_archive "$work"
  checksum=$(sha256sum "$work/desk.tar" | cut -d ' ' -f 1)
  if [[ ! -d "$data/artifacts/$checksum" ]]; then mv -- "$work" "$data/artifacts/$checksum"; fi
  printf '%s\n' "$checksum" > "$data/prepared.next"
  mv -- "$data/prepared.next" "$data/prepared"
  printf 'Scanned, signed and verified the local OCI archive.\n'
fi

if [[ "$mode" == prepare ]]; then exit 0; fi
read -r checksum < "$data/prepared"
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]]
artifact="$data/artifacts/$checksum"
printf '%s  %s\n' "$checksum" "$artifact/desk.tar" | sha256sum --check --status
verify_archive "$artifact"
expected=$(tar -xOf "$artifact/desk.tar" index.json | jq -er '.manifests | if length == 1 then .[0].digest else error("Expected one OCI manifest") end')
[[ "$expected" =~ ^sha256:[a-f0-9]{64}$ ]]
ssh -F "$lab_data/ssh.conf" "$lab_instance" 'sudo k3s ctr --namespace k8s.io images import --digests -' < "$artifact/desk.tar"
digest=$(ssh -F "$lab_data/ssh.conf" "$lab_instance" 'sudo k3s ctr --namespace k8s.io images ls' |
  awk -v name="$tag" '$1 == name { print $3 }')
[[ "$digest" == "$expected" ]]
ref="localhost/security-desk@$digest"
ssh -F "$lab_data/ssh.conf" "$lab_instance" "sudo k3s ctr --namespace k8s.io images tag --force $tag $ref" >/dev/null
scripts/deploy-desk.sh "$ref"
printf '%s\n' "$ref" > "$image_ref"
