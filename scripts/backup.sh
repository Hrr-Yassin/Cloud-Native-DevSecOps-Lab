#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
action="${1:?Choose export or restore-check}"
case "$action" in
  export)
    source scripts/verify-target.sh
    require_lab_context
    recipient="${2:?Provide an age recipients file}"
    archive="${3:?Provide a destination for the encrypted backup}"
    [[ -d "$(dirname "$archive")" && ! -e "$archive" ]]
    pod=$(kubectl -n security-desk get pods -l app.kubernetes.io/name=desk -o json |
      jq -er '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running"
        and any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name]
        | if length == 1 then .[0] else error("Expected exactly one ready Desk pod") end')
    remote="/tmp/desk-backup-$(openssl rand -hex 8).sqlite"
    temp=$(mktemp "$(dirname "$archive")/.backup.XXXXXX")
    cleanup_export() {
      rm -f -- "$temp"
      kubectl -n security-desk exec "pod/$pod" -c desk -- node -e \
        'require("node:fs").rmSync(process.argv[1], {force: true})' "$remote" >/dev/null 2>&1 || true
    }
    trap cleanup_export EXIT
    snapshot=$(kubectl -n security-desk exec "pod/$pod" -c desk -- node app/cli.mjs backup "$remote")
    kubectl -n security-desk exec "pod/$pod" -c desk -- node -e \
      'require("node:fs").createReadStream(process.argv[1]).pipe(process.stdout)' "$remote" |
      age -R "$recipient" > "$temp"
    ln -T -- "$temp" "$archive"
    printf '%s\n' "$snapshot"
    ;;
  restore-check)
    identity="${2:?Provide the age identity}"
    archive="${3:?Provide the encrypted backup}"
    temp=$(mktemp -d)
    trap 'rm -rf -- "$temp"' EXIT
    age --decrypt -i "$identity" -o "$temp/restored.sqlite" "$archive"
    node --disable-warning=ExperimentalWarning app/cli.mjs inspect "$temp/restored.sqlite"
    ;;
  *)
    printf 'Usage: %s {export <recipients> <encrypted-backup>|restore-check <identity> <encrypted-backup>}\n' "$0" >&2
    exit 64
    ;;
esac
