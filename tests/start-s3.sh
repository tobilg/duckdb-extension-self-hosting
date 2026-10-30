#!/usr/bin/env bash
# Starts an S3-compatible store (SeaweedFS) over TLS on localhost and creates the test buckets.
# Usage: start-s3.sh <directory for certs and config>
# Prints the settings as KEY=value lines, ready for $GITHUB_ENV. Removes nothing: see stop-s3.sh.

set -euo pipefail

dir=$1
port=${S3_TEST_PORT:-19000}
image=chrislusf/seaweedfs:4.51
key_id=testaccesskey
secret=testsecretkey123
public_buckets="public-bucket rotate-bucket wasm-bucket"
private_buckets="private-bucket env-bucket"

mkdir -p "$dir/certs" "$dir/config"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/certs/private.key" -out "$dir/certs/public.crt" -days 1 \
	-subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
chmod 644 "$dir/certs/private.key" "$dir/certs/public.crt"
ca="$dir/certs/public.crt"

# Anonymous requests can read the public buckets, like a bucket with a public access policy.
anonymous_actions=$(for bucket in $public_buckets; do printf '"Read:%s",' "$bucket"; done)
cat >"$dir/config/s3.json" <<EOF
{
  "identities": [
    {
      "name": "admin",
      "credentials": [{"accessKey": "$key_id", "secretKey": "$secret"}],
      "actions": ["Admin", "Read", "Write", "List", "Tagging"]
    },
    {
      "name": "anonymous",
      "actions": [${anonymous_actions%,}]
    }
  ]
}
EOF
chmod 644 "$dir/config/s3.json"

docker rm -f duckdb-publisher-s3 >/dev/null 2>&1 || true
# Every bucket allocates 7 volumes as soon as it gets its first object, so -volume.max has to cover all of them.
docker run -d --name duckdb-publisher-s3 -p "127.0.0.1:$port:8333" \
	-v "$dir/certs:/certs:ro" -v "$dir/config:/config:ro" "$image" \
	server -dir=/data -ip=127.0.0.1 -ip.bind=0.0.0.0 -volume.max=100 -master.volumeSizeLimitMB=256 \
	-s3 -s3.port=8333 -s3.config=/config/s3.json -s3.cert.file=/certs/public.crt -s3.key.file=/certs/private.key >/dev/null

endpoint="https://127.0.0.1:$port"

# Retries until the gateway and its filer accept the request, which takes a few seconds after the container starts.
create_bucket() { # <bucket>
	local attempts=0 status=000
	until [ "$status" = "200" ]; do
		attempts=$((attempts + 1))
		if [ "$attempts" -gt 300 ]; then
			echo "Could not create bucket $1, last status $status" >&2
			docker logs --tail 30 duckdb-publisher-s3 >&2
			exit 1
		fi
		status=$(curl -s --cacert "$ca" -o /dev/null -w '%{http_code}' -X PUT \
			--aws-sigv4 "aws:amz:us-east-1:s3" --user "$key_id:$secret" "$endpoint/$1" || true)
		if [ "$status" != "200" ]; then perl -e 'select(undef, undef, undef, 0.2)'; fi
	done
}

for bucket in $public_buckets $private_buckets; do
	create_bucket "$bucket"
done

cat <<EOF
S3_ENDPOINT=$endpoint
S3_ACCESS_KEY_ID=$key_id
S3_SECRET_ACCESS_KEY=$secret
RCLONE_CA_CERT=$ca
EOF
