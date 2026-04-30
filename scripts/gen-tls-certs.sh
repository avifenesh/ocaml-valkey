#!/usr/bin/env bash
# Generate self-signed TLS certs for local Valkey dev/test.
# Output goes to ./tls/. Safe to re-run; skips if files already present.
#
# Produces:
#   ca.crt / ca.key          — test CA (re-generated only if missing)
#   server.crt / server.key  — Valkey server cert signed by ca.crt
#   client.crt / client.key  — mTLS client cert signed by ca.crt
#                              (for tests of Tls_config.with_client_cert)
set -euo pipefail

CERT_DIR="${1:-./tls}"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

have_all=1
for f in ca.crt ca.key server.crt server.key client.crt client.key; do
  [ -f "$f" ] || have_all=0
done
if [ "$have_all" = 1 ]; then
  echo "tls certs already present in $(pwd), skipping"
  exit 0
fi

if [ ! -f ca.crt ] || [ ! -f ca.key ]; then
  echo "--- generating CA ---"
  openssl genrsa -out ca.key 2048
  openssl req -new -x509 -key ca.key -out ca.crt -days 365 \
    -subj "/CN=Valkey Test CA"
fi

if [ ! -f server.crt ] || [ ! -f server.key ]; then
  echo "--- generating server cert ---"
  openssl genrsa -out server.key 2048
  openssl req -new -key server.key -out server.csr -subj "/CN=localhost"
  cat >server.ext <<EOF
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 365 -extfile server.ext
  rm -f server.csr server.ext
fi

if [ ! -f client.crt ] || [ ! -f client.key ]; then
  echo "--- generating client cert ---"
  openssl genrsa -out client.key 2048
  openssl req -new -key client.key -out client.csr -subj "/CN=valkey-client"
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days 365
  rm -f client.csr
fi

rm -f ca.srl
chmod 644 server.key ca.key client.key
echo "--- done: $(pwd) ---"
ls -la
