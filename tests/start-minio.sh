#!/usr/bin/env bash
# Starts MinIO over TLS on localhost and creates the test buckets. Usage: start-minio.sh <directory for certs and data>
# Prints the settings as KEY=value lines, ready for $GITHUB_ENV. Removes nothing: see stop-minio.sh.

set -euo pipefail

dir=$1
port=${MINIO_PORT:-19000}
network=duckdb-publisher-test
key_id=testaccesskey
secret=testsecretkey123

mkdir -p "$dir/certs" "$dir/data"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/certs/private.key" -out "$dir/certs/public.crt" -days 1 \
	-subj "/CN=minio" -addext "subjectAltName=DNS:minio,IP:127.0.0.1" 2>/dev/null
chmod 644 "$dir/certs/private.key" "$dir/certs/public.crt"

docker rm -f duckdb-publisher-minio >/dev/null 2>&1 || true
docker network rm "$network" >/dev/null 2>&1 || true
docker network create "$network" >/dev/null
docker run -d --name duckdb-publisher-minio --network "$network" --network-alias minio -p "127.0.0.1:$port:9000" \
	-e MINIO_ROOT_USER=$key_id -e MINIO_ROOT_PASSWORD=$secret \
	-v "$dir/certs:/certs:ro" minio/minio server /tmp/data --certs-dir /certs >/dev/null

attempts=0
until curl -s --cacert "$dir/certs/public.crt" -o /dev/null "https://127.0.0.1:$port/minio/health/live"; do
	attempts=$((attempts + 1))
	if [ "$attempts" -gt 300 ]; then
		echo "MinIO did not start" >&2
		docker logs duckdb-publisher-minio >&2
		exit 1
	fi
	perl -e 'select(undef, undef, undef, 0.2)'
done

mc() {
	docker run --rm --network "$network" -v "$dir/certs:/root/.mc/certs/CAs:ro" \
		-e MC_HOST_local="https://$key_id:$secret@minio:9000" minio/mc "$@" >/dev/null
}
for bucket in private-bucket public-bucket rotate-bucket wasm-bucket env-bucket; do
	mc mb "local/$bucket"
done
for bucket in public-bucket rotate-bucket wasm-bucket; do
	mc anonymous set download "local/$bucket"
done

cat <<EOF
S3_ENDPOINT=https://127.0.0.1:$port
S3_ACCESS_KEY_ID=$key_id
S3_SECRET_ACCESS_KEY=$secret
RCLONE_CA_CERT=$dir/certs/public.crt
EOF
