#!/bin/bash
# Creates a self-signed code-signing certificate for release builds and prints how to store it as
# GitHub Actions secrets. Run ONCE; keep the .p12 and its password safe (password manager).
# Losing it, or replacing it, forces every user to re-grant macOS permissions.
# Usage: scripts/make-release-cert.sh <output-dir-OUTSIDE-the-repo> ["Certificate Name"]
set -euo pipefail
OUT="${1:?usage: $0 <output-dir outside the repo> [certificate name]}"
NAME="${2:-Org Screen Saver Release}"
case "$(cd "$OUT" 2>/dev/null && pwd -P || echo "$OUT")" in
  "$(cd "$(dirname "$0")/.." && pwd -P)"*) echo "Choose an output directory outside the repository."; exit 1;; esac
mkdir -p "$OUT"; chmod 700 "$OUT"
PASS="$(openssl rand -base64 24)"
cat > "$OUT/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -config "$OUT/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -name "$NAME" -out "$OUT/release.p12" -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
rm -f "$OUT/key.pem" "$OUT/cert.cnf"
chmod 600 "$OUT/release.p12" "$OUT/cert.pem"
echo "$PASS" > "$OUT/release.p12.password"; chmod 600 "$OUT/release.p12.password"
cat <<EOF

Created in $OUT:
  release.p12            certificate + private key (SECRET)
  release.p12.password   its password (SECRET)

Store as GitHub secrets (from the repo directory):
  base64 -i "$OUT/release.p12" | gh secret set RELEASE_CERT_P12_BASE64
  gh secret set RELEASE_CERT_PASSWORD < "$OUT/release.p12.password"

Then back the two files up somewhere safe (not the repo) and tag a release.
Valid for 10 years.
EOF
