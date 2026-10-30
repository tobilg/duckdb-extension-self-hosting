#!/usr/bin/env bash
# Removes what start-minio.sh created.

docker rm -f duckdb-publisher-minio >/dev/null 2>&1
docker network rm duckdb-publisher-test >/dev/null 2>&1
exit 0
