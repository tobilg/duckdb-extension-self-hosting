#!/usr/bin/env bash
# Writes the signing key to a private file, and the public keys into the bundle. sign.sh runs this, and is the only script
# that reads the private key file. It deletes the file as soon as the last binary is signed, and cleanup.sh covers runs that
# are killed before that.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

umask 077
key_file="$WORK_DIR/keys/signing_key.pem"
public_dir="$WORK_DIR/bundle/keys"
mkdir -p "$WORK_DIR/keys" "$public_dir"

pem_text "$INPUT_SIGNING_KEY" >"$key_file"

public_key_file="$public_dir/public_0.pem"
if ! openssl pkey -in "$key_file" -pubout -out "$public_key_file" 2>/dev/null; then
	die "Input 'signing-key' is not a readable PEM private key. It must not be encrypted."
fi
check_public_key "$public_key_file" "Input 'signing-key'"

fingerprint=$(fingerprint_of "$public_key_file")
set_output fingerprint "$fingerprint"
info "Signing key fingerprint: $fingerprint"

# The key file lists the signing key first, then any further keys.
if [ -n "${INPUT_ADDITIONAL_PUBLIC_KEYS:-}" ]; then
	pem_text "$INPUT_ADDITIONAL_PUBLIC_KEYS" | awk -v dir="$public_dir" '
		/-----BEGIN PUBLIC KEY-----/ { count++; file = dir "/public_" count ".pem" }
		file { print > file }
		/-----END PUBLIC KEY-----/ { close(file); file = "" }
	'
	if [ ! -f "$public_dir/public_1.pem" ]; then
		die "Input 'additional-public-keys' holds no PEM public key (-----BEGIN PUBLIC KEY-----)."
	fi
	index=1
	while [ -f "$public_dir/public_$index.pem" ]; do
		check_public_key "$public_dir/public_$index.pem" "Additional public key $index"
		info "Additional public key $index: $(fingerprint_of "$public_dir/public_$index.pem")"
		index=$((index + 1))
	done
fi
