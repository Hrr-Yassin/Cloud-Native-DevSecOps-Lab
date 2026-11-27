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
    remote="/tmp/desk-backup-$(openssl rand -hex 8).sqlite"
    temp=$(mktemp "$(dirname "$archive")/.backup.XXXXXX")
    trap 'rm -f -- "$temp"; kubectl exec -n security-desk deploy/desk -- node -e "require(\"node:fs\").rmSync(process.argv[1],{force:true})" "$remote" >/dev/null 2>&1 || true' EXIT
    kubectl exec -n security-desk deploy/desk -- node app/cli.mjs backup "$remote"
    kubectl exec -n security-desk deploy/desk -- node -e \
      'process.stdout.write(require("node:fs").readFileSync(process.argv[1]))' "$remote" |
      age -R "$recipient" > "$temp"
    mv -n -- "$temp" "$archive"
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
