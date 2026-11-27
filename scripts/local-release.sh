#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/verify-target.sh
require_lab_context
[[ "$(kubectl config current-context)" == devsecops-lab ]]
data="$PWD/.lab/local-release"
mkdir -p "$data"
[[ -s "$data/signing.key" && -s "$data/signing.pub" ]] || {
  printf 'Generate the dedicated signing key with cosign generate-key-pair --output-key-prefix .lab/local-release/signing.\n' >&2
  exit 64
}
work=$(mktemp -d "$data/build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
tag=localhost/security-desk:local
podman build --pull=always --file Containerfile --tag "$tag" .
podman save --format oci-archive --output "$work/desk.tar" "$tag"
scripts/image-gates.sh "$work/desk.tar" .reports
cosign sign-blob --yes --key "$data/signing.key" --new-bundle-format=false --use-signing-config=false \
  --tlog-upload=false --output-signature "$work/desk.sig" "$work/desk.tar"
cosign verify-blob --key "$data/signing.pub" --signature "$work/desk.sig" \
  --insecure-ignore-tlog=true "$work/desk.tar"

ssh -F .lab/ssh.conf devsecops-lab 'sudo k3s ctr --namespace k8s.io images import --digests -' < "$work/desk.tar"
digest=$(ssh -F .lab/ssh.conf devsecops-lab 'sudo k3s ctr --namespace k8s.io images ls' |
  awk -v name="$tag" '$1 == name { print $3 }')
[[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
ref="localhost/security-desk@$digest"
ssh -F .lab/ssh.conf devsecops-lab "sudo k3s ctr --namespace k8s.io images tag --force $tag $ref" >/dev/null
install -m 0600 "$work/desk.tar" "$data/desk.tar"
install -m 0600 "$work/desk.sig" "$data/desk.sig"
printf '%s\n' "$ref" > "$data/image.ref"
scripts/deploy-desk.sh "$ref"
