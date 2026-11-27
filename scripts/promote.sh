#!/usr/bin/env bash
set -euo pipefail
image="${1:?The digest of the workflow-signed GHCR image is required}"
repository="${2:?The GitHub owner/repository is required}"
here="$(dirname "$0")"
source "$here/verify-target.sh"
require_lab_context
"$here/verify-release.sh" "$image" "$repository"

snapshot="$(kubectl -n security-desk get deployment desk -o json)"
previous="$(jq -er '.spec.template.spec.containers[0] | select(.name == "desk").image' <<< "$snapshot")"
image_path=/spec/template/spec/containers/0/image

change_image() {
  local old=$1 new=$2
  local patch
  patch=$(jq -nc --arg old "$old" --arg new "$new" --arg path "$image_path" '[
    {op:"test",path:"/spec/template/spec/containers/0/name",value:"desk"},
    {op:"test",path:$path,value:$old}, {op:"replace",path:$path,value:$new}
  ]')
  kubectl -n security-desk patch deployment desk --type=json --patch "$patch" -o jsonpath='{.metadata.generation}'
}

wait_ready() {
  local expected=$1 generation=$2 state
  for attempt in {1..60}; do
    state="$(kubectl -n security-desk get deployment desk -o json)" || return 1
    jq -e --arg image "$expected" '.spec.template.spec.containers[0].image == $image' <<< "$state" >/dev/null ||
      return 1
    if jq -e --argjson generation "$generation" '
      .status.observedGeneration >= $generation
      and .status.updatedReplicas == 1 and .status.availableReplicas == 1
    ' <<< "$state" >/dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

generation=$(change_image "$previous" "$image")
if wait_ready "$image" "$generation"; then
  printf 'Verified digest is deployed and ready.\n'
  exit 0
fi

if [[ "$previous" != "$image" ]] && rollback=$(change_image "$image" "$previous") && wait_ready "$previous" "$rollback"; then
  printf 'Deployment failed readiness. The prior digest is ready after rollback.\n' >&2
else
  printf 'Deployment failed readiness. Inspect the current workload state.\n' >&2
fi
exit 1
