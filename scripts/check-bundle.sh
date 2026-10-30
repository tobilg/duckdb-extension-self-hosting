#!/usr/bin/env bash
# Checks the signed tree this job downloaded from the sign job. A job that runs the extension's native code shares the
# workflow run's artifacts, so publishing only trusts a tree with the digest that the sign job reported.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bundle_dir="$WORK_DIR/bundle"

[ -s "$bundle_dir/manifest.jsonl" ] || die "The signed tree wasn't found. Check that the sign job ran first and that 'signed-artifact' is the same in both jobs."
[ -f "$bundle_dir/keys/public_0.pem" ] || die "The signed tree has no public key."

if [ -n "${INPUT_BUNDLE_DIGEST:-}" ]; then
	actual=$(bundle_digest "$bundle_dir")
	[ "$actual" = "$INPUT_BUNDLE_DIGEST" ] || die "The signed tree doesn't match 'bundle-digest', so it changed after the sign job. Got $actual."
fi

set_output signed-dir "$bundle_dir/signed"
set_output fingerprint "$(fingerprint_of "$bundle_dir/keys/public_0.pem")"
