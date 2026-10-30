#!/usr/bin/env bash
# Runs the action's scripts for one job, the way action.yml does, without GitHub. Takes its inputs from INPUT_* variables,
# and applies the same defaults as action.yml. TEST_BUNDLE stands in for the signed tree that later jobs download. Writes
# outputs and summary to RUN_OUTPUT_FILE and RUN_SUMMARY_FILE. tests/unit.sh checks that this file and action.yml run the
# same scripts in the same order.

set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scripts="$root/scripts"

export INPUT_MODE=${INPUT_MODE:-}
export INPUT_ALL_EXTENSIONS=${INPUT_ALL_EXTENSIONS:-false}
export INPUT_UPLOAD_LATEST=${INPUT_UPLOAD_LATEST:-true}
export INPUT_UPLOAD_VERSIONED=${INPUT_UPLOAD_VERSIONED:-true}
export INPUT_OVERWRITE_VERSIONED=${INPUT_OVERWRITE_VERSIONED:-false}
export INPUT_PUBLISH_KEY_FILE=${INPUT_PUBLISH_KEY_FILE:-true}
export INPUT_ALLOW_KEY_CHANGE=${INPUT_ALLOW_KEY_CHANGE:-false}
export INPUT_ALLOW_DOWNGRADE=${INPUT_ALLOW_DOWNGRADE:-false}
export INPUT_CHECK_REPOSITORY=${INPUT_CHECK_REPOSITORY:-true}
export GITHUB_OUTPUT=${RUN_OUTPUT_FILE:?}
export GITHUB_STEP_SUMMARY=${RUN_SUMMARY_FILE:?}

has() { if [ -n "${1:-}" ]; then printf 'true'; else printf 'false'; fi; }
export HAS_SIGNING_KEY HAS_S3_ACCESS_KEY_ID HAS_S3_SECRET_ACCESS_KEY HAS_S3_SESSION_TOKEN
HAS_SIGNING_KEY=$(has "${INPUT_SIGNING_KEY:-}")
HAS_S3_ACCESS_KEY_ID=$(has "${INPUT_S3_ACCESS_KEY_ID:-}")
HAS_S3_SECRET_ACCESS_KEY=$(has "${INPUT_S3_SECRET_ACCESS_KEY:-}")
HAS_S3_SESSION_TOKEN=$(has "${INPUT_S3_SESSION_TOKEN:-}")

status=0
"${BASH:-bash}" "$scripts/setup.sh" || status=$?
setup_status=$status
WORK_DIR=$(sed -n 's/^work-dir=//p' "$GITHUB_OUTPUT" | sed -n 1p)
export WORK_DIR
export SOURCE_DIR=${INPUT_PATH:-$WORK_DIR/artifacts}

step() { # <script>
	if [ "$status" = "0" ]; then
		"${BASH:-bash}" "$scripts/$1" || status=$?
	fi
}

# The outcome of the step just run, like steps.<id>.outcome.
outcome() { # <status before the step>
	if [ "$1" != "0" ]; then printf 'skipped'; elif [ "$status" = "0" ]; then printf 'success'; else printf 'failure'; fi
}

if [ "$INPUT_MODE" = "sign" ]; then
	step sign.sh
elif [ "$status" = "0" ] && [ -n "${TEST_BUNDLE:-}" ]; then
	cp -R "$TEST_BUNDLE/." "$WORK_DIR/bundle/"
fi
if [ "$INPUT_MODE" != "sign" ]; then
	step check-bundle.sh
fi
if [ "$INPUT_MODE" = "verify" ]; then
	before=$status
	step smoke-test.sh
	SMOKE_TEST_OUTCOME=$(outcome "$before")
	export SMOKE_TEST_OUTCOME
fi
if [ "$INPUT_MODE" = "publish" ]; then
	step install-rclone.sh
	before=$status
	step upload.sh
	UPLOAD_OUTCOME=$(outcome "$before")
	export UPLOAD_OUTCOME
	if [ "$INPUT_CHECK_REPOSITORY" != "false" ]; then
		before=$status
		step check-repository.sh
		CHECK_OUTCOME=$(outcome "$before")
		export CHECK_OUTCOME
	fi
fi
# Also runs after a failure, because a failed upload or check can leave objects live.
if [ "$setup_status" = "0" ]; then
	"${BASH:-bash}" "$scripts/summary.sh" || status=$?
fi

"${BASH:-bash}" "$scripts/cleanup.sh"
exit "$status"
