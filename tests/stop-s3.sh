#!/usr/bin/env bash
# Removes what start-s3.sh created.

docker rm -f duckdb-publisher-s3 >/dev/null 2>&1
exit 0
