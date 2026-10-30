#!/usr/bin/env bash
# Removes the private key and intermediate files. Runs even if an earlier step failed, and keeps signed-dir for later steps.

set -uo pipefail

[ -n "${WORK_DIR:-}" ] || exit 0
rm -f "$WORK_DIR/keys/signing_key.pem"
rm -rf "${WORK_DIR:?}/tmp" "${WORK_DIR:?}/artifacts" "${WORK_DIR:?}/cli"
exit 0
