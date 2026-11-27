#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]]
destination="${1:?Provide a destination directory}"
mkdir -p "$destination"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

download() {
  local name=$1 url=$2 asset=$3 checksum=$4 member=${5:-$1}
  curl --fail --silent --show-error --location --retry 3 --max-time 180 \
    --proto '=https' --proto-redir '=https' "$url" -o "$work/$asset"
  printf '%s  %s\n' "$checksum" "$work/$asset" | sha256sum --check --status
  case "$asset" in
    age-*.tar.gz)
      tar -xzf "$work/$asset" -C "$work" age/age age/age-keygen
      install -m 0755 "$work/age/age" "$work/age/age-keygen" "$destination/"
      return
      ;;
    *.tar.gz) tar -xzf "$work/$asset" -C "$work" "$member";;
    *) member=$asset;;
  esac
  install -m 0755 "$work/$member" "$destination/$name"
}

github_release() {
  local name=$1 repo=$2 release=$3 asset=$4 checksum=$5
  download "$name" "https://github.com/$repo/releases/download/$release/$asset" \
    "$asset" "$checksum" "${6:-$name}"
}

for tool in "${@:2}"; do
  case "$tool" in
    age)
      github_release age FiloSottile/age v1.3.2 age-v1.3.2-linux-amd64.tar.gz \
        cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10 ;;
    trivy)
      github_release trivy aquasecurity/trivy v0.74.0 trivy_0.74.0_Linux-64bit.tar.gz \
        2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a ;;
    gitleaks)
      github_release gitleaks gitleaks/gitleaks v8.30.0 gitleaks_8.30.0_linux_x64.tar.gz \
        79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e ;;
    actionlint)
      github_release actionlint rhysd/actionlint v1.7.12 actionlint_1.7.12_linux_amd64.tar.gz \
        8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
    k3d)
      github_release k3d k3d-io/k3d v5.9.0 k3d-linux-amd64 \
        06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0 ;;
    cosign)
      github_release cosign sigstore/cosign v3.1.6 cosign-linux-amd64 \
        318a99ade4156a0c4113aa983b46c0a0830fa7896a096c63121ee47b610a94c6 ;;
    tofu)
      github_release tofu opentofu/opentofu v1.10.10 tofu_1.10.10_linux_amd64.tar.gz \
        75b529fd9481b23e46a895520883f04c537bd6be4bd0dff83ad87e85806b12f1 ;;
    kubectl)
      download kubectl https://dl.k8s.io/release/v1.35.10/bin/linux/amd64/kubectl kubectl \
        c49a28f1f4efc4d475ed05f47f2ce8e563bf7bef69ed77fe1b924ea6d83b6327 ;;
    helm)
      download helm https://get.helm.sh/helm-v3.22.1-linux-amd64.tar.gz helm.tar.gz \
        896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea linux-amd64/helm ;;
    uv)
      github_release uv astral-sh/uv 0.11.12 uv-x86_64-unknown-linux-gnu.tar.gz \
        9acdecddacba550ee616c02bb4616d894352022550c5977524556fd5077ce1d4 uv-x86_64-unknown-linux-gnu/uv ;;
    *) printf 'Unknown tool %s\n' "$tool" >&2; exit 64;;
  esac
done
