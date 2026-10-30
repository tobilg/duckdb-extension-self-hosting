# DuckDB Extension Publisher

A GitHub Action that signs DuckDB extensions with your own key and publishes them to a [custom extension repository](https://duckdb.org/docs/2.0/extensions/extension_repositories) on S3-compatible storage. Clients install them without `-unsigned`.

It runs after DuckDB's standard build and does the rest in one step:

- Finds the built binaries and checks their footers.
- Signs each one and verifies the signature before anything leaves the runner.
- Uploads them to the paths DuckDB requests, along with an optional key file.
- Installs and loads the result with the real DuckDB CLI.

> **Status:** pre-release, and DuckDB's docs mark custom repositories as work in progress. It's tested against MinIO. A release from a real extension to Cloudflare R2 is still open, and `v1` follows once that has passed.

## Quick start

### 1. Create a signing key

```bash
openssl genrsa -out signing_key.pem 2048
openssl rsa -in signing_key.pem -pubout -out signing_key.pub
openssl pkey -pubin -in signing_key.pub -outform DER | openssl dgst -sha256
```

The last line prints the key's fingerprint. Publish it somewhere other than the bucket, so that clients can check it.

Create a second key the same way and keep it offline. Pinning both from the start makes [rotation](#rotating-keys) much easier.

### 2. Add the secrets

| Secret | Value |
| --- | --- |
| `EXTENSION_SIGNING_KEY` | Contents of `signing_key.pem` |
| `S3_ENDPOINT` | Your store's S3 API, such as `https://<account_id>.r2.cloudflarestorage.com`. Leave out the input on AWS. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | A token with read and write access to the bucket's objects |

Prefer [environment secrets](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) with required reviewers, so that the key is only available to the release job. On AWS, you can skip the static keys: role assumption through OIDC sets the `AWS_*` variables, and the action picks those up.

### 3. Add the workflow

```yaml
on:
  push:
    tags: ['v*']

jobs:
  build:
    uses: duckdb/extension-ci-tools/.github/workflows/_extension_distribution.yml@v2.0-cyanoptera
    with:
      duckdb_version: v2.0.0
      ci_tools_version: v2.0-cyanoptera
      extension_name: my_ext

  publish:
    needs: build
    runs-on: ubuntu-24.04
    environment: release
    steps:
      - uses: tobilg/duckdb-extension-self-hosting@v1
        with:
          extension-name: my_ext
          signing-key: ${{ secrets.EXTENSION_SIGNING_KEY }}
          s3-endpoint: ${{ secrets.S3_ENDPOINT }}
          s3-bucket: my-extensions
          s3-access-key-id: ${{ secrets.S3_ACCESS_KEY_ID }}
          s3-secret-access-key: ${{ secrets.S3_SECRET_ACCESS_KEY }}
          repository-url: https://extensions.example.com
```

One Linux job publishes the binaries of every platform. [`examples/release.yml`](examples/release.yml) has a commented version.

### 4. Install it

Each client opts in and pins your key once per machine. The job summary of each run has this SQL filled in:

```sql
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo
    WITH PREFIX 'https://extensions.example.com'
    USING PUBLIC KEY '-----BEGIN PUBLIC KEY----- ...';
INSTALL my_ext FROM my_repo;
LOAD my_ext FROM my_repo;
```

Later sessions only need `LOAD my_ext FROM my_repo;`. To upgrade, run `FORCE INSTALL my_ext FROM my_repo;` after the opt-in, because `UPDATE EXTENSIONS` skips these extensions. Autoloading and a bare `LOAD my_ext` don't work either: DuckDB only uses your key when you name the repository. The [DuckDB docs](https://duckdb.org/docs/2.0/extensions/extension_repositories#using-a-repository) have the details.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `signing-key` | required | RSA-2048 private key in PEM format, not encrypted |
| `extension-name` | | Extension to publish. Selects the artifacts, and skips other extensions found in them. |
| `artifact-pattern` | `<extension-name>-*-extension-*` | Glob for the workflow artifacts to download |
| `path` | | Directory that already holds the binaries, for other build systems. Nothing is downloaded. |
| `mode` | `publish` | `sign-only` stops after signing and leaves a repository tree in `signed-dir` |
| `exclude-platforms` | | Comma or space separated platforms to skip |
| `duckdb-version` | from the footer | DuckDB version directory, or a comma separated list. Only required for `C_STRUCT` builds. |
| `extension-version` | from the footer | Version in the versioned path |
| `additional-public-keys` | | Further public keys for the key file, such as your reserve key |
| `s3-bucket` | | Required in `publish` mode |
| `s3-prefix` | | Key prefix inside the bucket |
| `s3-endpoint` | AWS | S3 API endpoint. Must be `https://`. |
| `s3-region` | `AWS_REGION`, or `auto` on R2 | Bucket region |
| `s3-provider` | detected | [rclone provider](https://rclone.org/s3/) |
| `s3-access-key-id`, `s3-secret-access-key`, `s3-session-token` | `AWS_*` variables | Credentials |
| `upload-latest` | `true` | Upload to the path `INSTALL` reads |
| `upload-versioned` | `true` | Upload to the path `INSTALL ... VERSION` reads |
| `overwrite-versioned` | `false` | Allow replacing a versioned object with different bytes |
| `publish-key-file` | `true` | Publish `.well-known/duckdb-extension-repo.json` |
| `smoke-test` | `true` | Install and load the result on this runner |
| `repository-url` | `s3://<bucket>/<prefix>` | Public prefix clients use |
| `smoke-test-setup-sql` | | SQL to run first in the smoke test, such as a custom CA file |

## Outputs

| Output | Description |
| --- | --- |
| `fingerprint` | Fingerprint of the signing key, in the format DuckDB reports it |
| `signed-dir` | Directory with the signed files, laid out like the repository |
| `files` | JSON array with platform, versions, ABI, object path and SHA-256 of each file |
| `repository-url` | Prefix for `CREATE EXTENSION REPOSITORY`. Empty in `sign-only` mode. |

## What ends up in the bucket

```text
.well-known/duckdb-extension-repo.json
<duckdb_version>/<platform>/<name>.duckdb_extension.gz
<name>/<extension_version>/<duckdb_version>/<platform>/<name>.duckdb_extension.gz
<duckdb_version>/wasm_<target>/<name>.duckdb_extension.wasm
```

Platform and versions come from the footer of each binary, not from the artifact name, so any build system works.

A new DuckDB release means new objects, depending on the ABI type:

- **`CPP` and `C_STRUCT_UNSTABLE`** builds only load in the exact DuckDB version they were built for, so rebuild them for each release.
- **`C_STRUCT`** builds against the stable C API can be loaded by later versions. List every version in `duckdb-version`, and the same signed binary is published to each directory.

## Serving the bucket

Clients only send `HEAD` and `GET`, so a public bucket can be served from any HTTPS endpoint. Clients reject anything not signed by a key they pinned, so the bucket doesn't have to be trusted.

| Prefix | Bucket | Clients need |
| --- | --- | --- |
| `https://extensions.example.com` | Public | httpfs, which DuckDB autoinstalls from its core repository |
| `s3://my-bucket` | Private | httpfs, plus a `CREATE SECRET (TYPE s3, ...)` for `INSTALL` |
| `http://extensions.example.com` | Public | Nothing extra, but DuckDB doesn't follow redirects here, so an HTTP-to-HTTPS redirect breaks it |

On Cloudflare R2, use a custom domain. Cloudflare says public access through `r2.dev` ["is rate-limited and should only be used for development purposes"](https://developers.cloudflare.com/r2/buckets/public-buckets/).

## Security

- **Pin the action by commit.** It handles your signing key: `uses: tobilg/duckdb-extension-self-hosting@<sha> # v1.0.0`.
- **Limit who can reach the key.** Use an environment with required reviewers, and only run the job on tags.
- **What the action does with the key.** It goes through one step's environment into a `0600` file, which is removed afterwards even if the run fails. It's never passed to rclone, and tracing is never turned on.
- **What it downloads.** rclone is pinned and checked against hashes stored in this repository. No `curl | bash`.
- **Published versions don't change.** Replacing a versioned object with different bytes fails unless you set `overwrite-versioned`. Re-running a release is safe, because the same input gives the same bytes.

What signing can't do, whichever tool you use:

- **Trust on first use.** Without `USING PUBLIC KEY`, clients trust whoever can write to the key file at that moment. Pass the key inline, or publish the fingerprint elsewhere.
- **No revocation or expiry.** A leaked key stays trusted until each client replaces its pin.
- **No rollback protection.** Signatures carry no timestamp, so anyone who can write to the bucket can serve an older, validly signed build.
- **No sandbox.** Extensions are native code with the privileges of the DuckDB process.

## Rotating keys

Keys only change when a client creates the repository again:

1. On each client, pin both keys with `CREATE OR REPLACE EXTENSION REPOSITORY ... USING PUBLIC KEYS '<old>', '<new>'`. Skip this if you pinned your reserve key from the start.
2. Publish with the new `signing-key`. List the old public key in `additional-public-keys`, and set `overwrite-versioned: true` if you re-sign an existing version.
3. On each client, run `FORCE INSTALL` for the installed extensions.
4. On each client, remove the old key with another `CREATE OR REPLACE`.

Removing a key makes builds signed with it fail on the next `LOAD`, so finish step 3 first.

## DuckDB-Wasm

**Experimental.** Wasm builds are signed and published automatically unless you exclude them. They need `brotli` on the runner, which `ubuntu-24.04` has. They get the latest path only, with `Content-Encoding: br` and `Content-Type: application/wasm`.

The tests load the action's output in headless Chrome with DuckDB-Wasm `1.33.1-dev110.0`. That covers `C_STRUCT` and `CPP` builds, and rejection of wrong keys, tampered files, bare `LOAD`, `custom_extension_repository` and direct URLs. Three things are different from native DuckDB:

- **No stable release yet.** The tested build is a dev build of the v2.0.0 commit, so it requests `<prefix>/d54cbbe3df/wasm_eh/...` rather than `v2.0.0/`. A stable DuckDB-Wasm 2.0 should request `v2.0.0/`, where DuckDB's own repository serves these files today. To test against the dev build now, set `duckdb-version: d54cbbe3df`.
- **The bucket needs CORS** that allows `GET` from your site's origin, or the fetch fails. The smoke test can't cover Wasm, so check this yourself.
- **The key must be inline.** Fetching the key file needs httpfs, which the tested build can't load.

There are two client setups. Use the first unless you need DuckDB's home directory in OPFS, for example for persistent secrets:

```js
// Home directory outside OPFS: the repository isn't kept, so pin the key on each page load.
await db.open({ homeDirectory: '/home/web_user' });
const conn = await db.connect();
await conn.query("SET allow_extension_repositories = 'allowed'");
await conn.query(`CREATE EXTENSION REPOSITORY my_repo WITH PREFIX '${prefix}' USING PUBLIC KEY '${publicKey}'`);
await conn.query('LOAD my_ext FROM my_repo');
```

```js
// Default home directory in OPFS: DuckDB-Wasm can only open files it prepared before a query, so prepare the
// repository files before CREATE reads an existing one, and again after it writes a new one.
const store = 'opfs://home/.duckdb/extension_repositories/*.repo.json';
await db.registerOPFSFileName(store, 'read');
await conn.query("SET allow_extension_repositories = 'allowed'");
await conn.query(`CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo WITH PREFIX '${prefix}' USING PUBLIC KEY '${publicKey}'`);
await db.registerOPFSFileName(store, 'read');
await conn.query('LOAD my_ext FROM my_repo');
```

The Node.js bindings of DuckDB-Wasm can't use custom repositories at the moment: `CREATE` leaves a temporary file behind, and the repository never appears.

## Development

```bash
bash tests/unit.sh        # no network, no Docker
bash tests/e2e.sh         # MinIO in Docker, real extensions, real DuckDB CLI
bash tests/wasm/run.sh    # DuckDB-Wasm in headless Chrome, needs Node.js
```

Scripts must keep running on bash 3.2, the stock bash on macOS. `duckdb`, `duckdb-web` and `duckdb-wasm` are submodules for reference only: GitHub doesn't fetch them when running the action, and nothing here reads them at runtime.

## License

[MIT](LICENSE). `scripts/compute-extension-hash.sh` is copied unchanged from DuckDB, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
