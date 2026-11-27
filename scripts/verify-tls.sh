#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
directory=$(mktemp -d)
trap 'rm -rf -- "$directory"' EXIT
scripts/issue-tls.sh "$directory"
first=$(sha256sum "$directory/ca.crt" "$directory/desk.crt")
scripts/issue-tls.sh "$directory"
[[ "$first" == "$(sha256sum "$directory/ca.crt" "$directory/desk.crt")" ]]
openssl verify -x509_strict -CAfile "$directory/ca.crt" -purpose sslserver \
  -verify_hostname desk.lab.invalid "$directory/desk.crt" | sed 's#^.*/##'
if openssl verify -x509_strict -CAfile "$directory/ca.crt" -purpose sslserver \
  -verify_hostname unrelated.invalid "$directory/desk.crt" >/dev/null 2>&1; then
  printf 'Unexpected success while verifying the unrelated hostname.\n' >&2
  exit 1
fi
[[ "$(stat -c '%a' "$directory/ca.key")" == 600 && "$(stat -c '%a' "$directory/desk.key")" == 600 ]]
printf 'Certificate issuance is idempotent. Hostname mismatch was rejected. Private keys use mode 0600.\n'
