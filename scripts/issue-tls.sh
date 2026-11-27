#!/usr/bin/env bash
set -euo pipefail
umask 077
directory="${1:?Provide a private directory for the lab TLS material}"
mkdir -p "$directory"
exec 9> "$directory/.issue.lock"
flock 9
work=$(mktemp -d "$directory/issued.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

verify_leaf() {
  openssl verify -x509_strict -CAfile "$directory/ca.crt" -purpose sslserver \
    -verify_hostname desk.lab.invalid "$directory/desk.crt"
}

if [[ ! -s "$directory/ca.key" && ! -s "$directory/ca.crt" ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc -sha256 -days 90 \
    -subj '/CN=DevSecOps Lab Local CA' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash' \
    -keyout "$work/ca.key" -out "$work/ca.crt" 2>/dev/null
  mv -- "$work/ca.key" "$work/ca.crt" "$directory/"
fi
[[ -s "$directory/ca.key" && -s "$directory/ca.crt" ]]
if [[ ! -s "$directory/desk.key" || ! -s "$directory/desk.crt" ]] ||
   ! openssl x509 -checkend 86400 -noout -in "$directory/desk.crt" >/dev/null ||
   ! verify_leaf >/dev/null 2>&1; then
  if ! openssl x509 -checkend "$((31 * 24 * 3600))" -noout -in "$directory/ca.crt" >/dev/null; then
    printf 'The local CA needs rotation before a new leaf can be issued.\n' >&2
    exit 1
  fi
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
    -subj '/CN=desk.lab.invalid' -keyout "$work/desk.key" -out "$work/desk.csr" 2>/dev/null
  cat > "$work/extensions" <<'EXTENSIONS'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:desk.lab.invalid
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
EXTENSIONS
  openssl x509 -req -in "$work/desk.csr" -CA "$directory/ca.crt" -CAkey "$directory/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days 30 -sha256 \
    -extfile "$work/extensions" -out "$work/desk.crt" 2>/dev/null
  mv -- "$work/desk.key" "$work/desk.crt" "$directory/"
fi
verify_leaf >/dev/null
[[ "$(openssl pkey -in "$directory/desk.key" -pubout)" == "$(openssl x509 -in "$directory/desk.crt" -pubkey -noout)" ]]
