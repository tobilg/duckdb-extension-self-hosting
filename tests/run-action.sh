#!/usr/bin/env bash
# Runs the action's scripts in the order action.yml does, without GitHub. Takes its inputs from INPUT_* variables, and
# applies the same defaults as action.yml. Writes outputs and summary to RUN_OUTPUT_FILE and RUN_SUMMARY_FILE.

set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scripts="$root/scripts"

export INPUT_MODE=${INPUT_MODE:-publish}
export INPUT_UPLOAD_LATEST=${INPUT_UPLOAD_LATEST:-true}
export INPUT_UPLOAD_VERSIONED=${INPUT_UPLOAD_VERSIONED:-true}
export INPUT_OVERWRITE_VERSIONED=${INPUT_OVERWRITE_VERSIONED:-false}
export INPUT_PUBLISH_KEY_FILE=${INPUT_PUBLISH_KEY_FILE:-true}
export INPUT_SMOKE_TEST=${INPUT_SMOKE_TEST:-true}
export GITHUB_OUTPUT=${RUN_OUTPUT_FILE:?}
export GITHUB_STEP_SUMMARY=${RUN_SUMMARY_FILE:?}

status=0
"${BASH:-bash}" "$scripts/setup-key.sh" || status=$?
WORK_DIR=$(sed -n 's/^work-dir=//p' "$GITHUB_OUTPUT" | sed -n 1p)
export WORK_DIR
export SOURCE_DIR=${INPUT_PATH:-$WORK_DIR/artifacts}

step() { # <script>
	if [ "$status" = "0" ]; then
		"${BASH:-bash}" "$scripts/$1" || status=$?
	fi
}

step sign.sh
if [ "$INPUT_MODE" != "sign-only" ]; then
	step install-rclone.sh
	step upload.sh
	if [ "$INPUT_SMOKE_TEST" = "true" ]; then step smoke-test.sh; fi
fi
step summary.sh

"${BASH:-bash}" "$scripts/cleanup.sh"
exit "$status"
