#!/usr/bin/env bash
# A CLI guard for scripts that apply resources or seed accounts.
require_lab_context() {
  local context server
  context="$(kubectl config current-context)"
  server="$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}')"
  case "$context:$server" in
    devsecops-lab:https://127.0.0.1:16443|k3d-dslab-ci:https://127.0.0.1:*)
      ;;
    *)
      printf 'Select the dedicated devsecops-lab or k3d-dslab-ci context.\n' >&2
      return 1
      ;;
  esac
}
