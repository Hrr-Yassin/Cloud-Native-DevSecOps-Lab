#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
action="${1:?Choose export, restore-check or restore-probe}"
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
  restore-probe)
    source scripts/verify-target.sh
    require_lab_context
    identity="${2:?Provide the age identity}"
    archive="${3:?Provide the encrypted backup}"
    [[ -r "$identity" && -r "$archive" ]]
    pod="desk-restore-$(openssl rand -hex 4)"
    namespace=security-desk
    boot='
      import { existsSync } from "node:fs";
      import { setTimeout as wait } from "node:timers/promises";
      while (!existsSync(process.env.DB_PATH)) await wait(200);
      await import("./app/main.mjs");
    '
    kubectl -n "$namespace" get deployment desk -o json |
      jq --arg name "$pod" --arg boot "$boot" '{
        apiVersion:"v1", kind:"Pod", metadata:{name:$name, labels:{"app.kubernetes.io/name":"desk-restore"}},
        spec:(.spec.template.spec | .restartPolicy = "Never" | .activeDeadlineSeconds = 240 |
          (.volumes[] | select(.name == "data")) = {name:"data", emptyDir:{sizeLimit:"256Mi"}} |
          (.containers[] | select(.name == "desk")).args = ["--input-type=module","-e",$boot])
      }' | kubectl -n "$namespace" create -f - >/dev/null
    cleanup_restore() { kubectl -n "$namespace" delete pod "$pod" --wait=false >/dev/null; }
    trap cleanup_restore EXIT
    kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Running "pod/$pod" --timeout=100s >&2
    restored=$(age --decrypt -i "$identity" "$archive" |
      kubectl -n "$namespace" exec -i "$pod" -c desk -- node --disable-warning=ExperimentalWarning --input-type=module -e '
        import { createWriteStream } from "node:fs";
        import { link, rm } from "node:fs/promises";
        import { pipeline } from "node:stream/promises";
        import { inspectBackup } from "./app/store.mjs";
        const target = process.env.DB_PATH;
        const stage = target + ".restore";
        await pipeline(process.stdin, createWriteStream(stage, { flags: "wx", mode: 0o600 }));
        const verified = inspectBackup(stage);
        await link(stage, target);
        await rm(stage);
        console.log(JSON.stringify(verified));
      ')
    kubectl -n "$namespace" wait --for=condition=Ready "pod/$pod" --timeout=75s >&2
    total=$(kubectl -n "$namespace" exec "$pod" -c desk -- node -e '
      fetch("http://127.0.0.1:9091/metrics", { signal: AbortSignal.timeout(4000) }).then(async response => {
        if (!response.ok) throw new Error("The restored service did not expose metrics");
        const series = (await response.text()).match(/^desk_findings\{[^}]+\} \d+$/gm);
        if (!series) throw new Error("Finding metrics are missing on the restored service");
        console.log(series.reduce((sum, sample) => sum + Number(sample.split(" ").at(-1)), 0));
      }).catch(error => { console.error(error.message); process.exitCode = 1; });
    ')
    jq -e --argjson total "$total" '
      select(.findings == $total) | {event:"restored_workload_ready",findings,volume:"isolated"}
    ' <<< "$restored"
    ;;
  *)
    printf 'Usage: %s {export <recipients> <encrypted-backup>|restore-check <identity> <encrypted-backup>|restore-probe <identity> <encrypted-backup>}\n' "$0" >&2
    exit 64
    ;;
esac
