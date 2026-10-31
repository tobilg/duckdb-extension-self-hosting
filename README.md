# DuckDB Extension Publisher

A GitHub Action that signs DuckDB extensions with your own key and publishes them to a [custom extension repository](https://duckdb.org/docs/2.0/extensions/extension_repositories) on S3-compatible storage. Clients install them without `-unsigned`.

It runs after DuckDB's standard build, in three jobs:

| Job | Has | Does |
| --- | --- | --- |
| `mode: sign` | The signing key | Finds the built binaries, checks their footers, signs each one and verifies the signature. Never runs them. |
| `mode: verify` | No secrets | Installs and loads the result with the real DuckDB CLI. Nothing has been uploaded yet, so a build that doesn't load stops here. |
| `mode: publish` | The storage credentials | Uploads to the paths DuckDB requests, along with an optional key file, and reads everything back through your public URL. |

The jobs are separate because `verify` runs your extension's native code, and a step can read every secret its job has. See [Security](#security).

> **Status:** pre-release, and DuckDB's docs mark custom repositories as work in progress. It's tested against a local S3-compatible store (SeaweedFS). A release from a real extension to Cloudflare R2 is still open, and `v1` follows once that has passed.

## Quick start

The shortest way to add this to an extension repository that uses DuckDB's standard build, such as one from [`extension-template`](https://github.com/duckdb/extension-template). [Full setup](#full-setup) adds what this leaves out.

### 1. Create a key and a bucket

You only need one of each, and your extensions can share them.

```bash
openssl genrsa -out signing_key.pem 2048
openssl rsa -in signing_key.pem -pubout -out signing_key.pub
```

Keep `signing_key.pem` safe and out of any repository, because a leaked key can't be revoked.

Then create a bucket that clients can read over HTTPS, and a token that can read, write and list its objects. On Cloudflare R2, give the bucket a [custom domain](#serving-the-bucket).

### 2. Add the secrets

In each extension repository:

```bash
REPO=<owner>/<repo>
gh secret set EXTENSION_SIGNING_KEY --repo "$REPO" < signing_key.pem
gh secret set S3_ENDPOINT --repo "$REPO" --body 'https://<account_id>.r2.cloudflarestorage.com'
gh secret set S3_ACCESS_KEY_ID --repo "$REPO"
gh secret set S3_SECRET_ACCESS_KEY --repo "$REPO"
```

The last two prompt for their values.

### 3. Add the jobs

Change the workflow that builds your extension, usually `.github/workflows/MainDistributionPipeline.yml`. It has to run on tags, so if `push` lists `branches`, add `tags` next to it. If `push` has no filters, it already runs on tags, so leave it as it is.

```yaml
on:
  push:
    branches: [main]
    tags: ['*']
```

Then add these jobs, and replace:

- `<commit-sha>` with the commit of a release of this action
- `my_ext` with the name of your extension
- `my-extensions` and `https://extensions.example.com` with your bucket and its public URL
- `duckdb-stable-build` with the name of your build job, if yours is different

```yaml
  sign:
    if: startsWith(github.ref, 'refs/tags/')
    needs: duckdb-stable-build
    runs-on: ubuntu-24.04
    outputs:
      bundle-digest: ${{ steps.sign.outputs.bundle-digest }}
      verify-runners: ${{ steps.sign.outputs.verify-runners }}
    steps:
      - id: sign
        uses: tobilg/duckdb-extension-self-hosting@<commit-sha> # v1.0.0
        with:
          mode: sign
          extension-name: my_ext
          signing-key: ${{ secrets.EXTENSION_SIGNING_KEY }}

  verify:
    needs: sign
    strategy:
      fail-fast: false
      matrix:
        os: ${{ fromJSON(needs.sign.outputs.verify-runners) }}
    runs-on: ${{ matrix.os }}
    permissions: {}
    steps:
      - uses: tobilg/duckdb-extension-self-hosting@<commit-sha> # v1.0.0
        with:
          mode: verify

  publish:
    needs: [sign, verify]
    runs-on: ubuntu-24.04
    concurrency:
      group: publish-my_ext
      cancel-in-progress: false
    steps:
      - uses: tobilg/duckdb-extension-self-hosting@<commit-sha> # v1.0.0
        with:
          mode: publish
          bundle-digest: ${{ needs.sign.outputs.bundle-digest }}
          s3-endpoint: ${{ secrets.S3_ENDPOINT }}
          s3-bucket: my-extensions
          s3-access-key-id: ${{ secrets.S3_ACCESS_KEY_ID }}
          s3-secret-access-key: ${{ secrets.S3_SECRET_ACCESS_KEY }}
          repository-url: https://extensions.example.com
```

On branches and pull requests, the three jobs are skipped. `verify` follows the platforms you build: see [Choosing platforms](#choosing-platforms).

### 4. Release

Merge that, then push a tag:

```bash
git tag 1.0.0 && git push origin 1.0.0
```

The tag has to be on a commit that has these jobs, because GitHub runs the workflow from the tagged commit. DuckDB's build uses the tag as the extension's version. Most builds [only load in the DuckDB version they were built for](#what-ends-up-in-the-bucket), so tag a new release for each DuckDB version too.

### 5. Install it

Each client opts in and pins your key once per machine:

```sql
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo
    WITH PREFIX 'https://extensions.example.com';
INSTALL my_ext FROM my_repo;
LOAD my_ext FROM my_repo;
```

Later sessions only need `LOAD my_ext FROM my_repo;`. To upgrade, run `FORCE INSTALL my_ext FROM my_repo;` after the opt-in, because `UPDATE EXTENSIONS` skips these extensions. Autoloading and a bare `LOAD my_ext` don't work either: DuckDB only uses your key when you name the repository. The [DuckDB docs](https://duckdb.org/docs/2.0/extensions/extension_repositories#using-a-repository) have the details.

### What this leaves out

- **Any workflow on any branch you push can read the secrets.** [Environment secrets](#secrets) limit them to the jobs that need them.
- **Changing your key means every client pins again.** A [reserve key](#signing-keys) avoids that.
- **Clients trust the key file the first time they connect.** They can [compare the fingerprints or pass the key inline](#pinning-the-key).

## Full setup

The same three jobs, with the protections the Quick start leaves out. [`examples/release.yml`](examples/release.yml) has this workflow with comments, and [`examples/release-aws-oidc.yml`](examples/release-aws-oidc.yml) uses an [AWS role](#publishing-to-aws-with-oidc) instead of storage keys.

### Signing keys

```bash
openssl genrsa -out signing_key.pem 2048
openssl rsa -in signing_key.pem -pubout -out signing_key.pub
openssl pkey -pubin -in signing_key.pub -outform DER | openssl dgst -sha256
```

The last line prints the key's fingerprint. Publish it somewhere other than the bucket, so that clients can check it.

Create a second key the same way, publish its fingerprint too, and keep the key offline. Pinning both from the start makes [rotation](#rotating-keys) much easier.

### Secrets

| Secret or variable | Value |
| --- | --- |
| `EXTENSION_SIGNING_KEY` | Contents of `signing_key.pem` |
| `EXTENSION_RESERVE_PUBLIC_KEY` | Contents of the second key's `.pub` file. A variable, because it's public. |
| `S3_ENDPOINT` | Your store's S3 API, such as `https://<account_id>.r2.cloudflarestorage.com`. Leave out the input on AWS. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | A token that can read, write and list the bucket's objects. On AWS, that's `s3:GetObject`, `s3:PutObject`, `s3:AbortMultipartUpload` and `s3:ListBucket`. |

Use [environment secrets](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments), which a job can only read if it names the environment:

- **One environment** keeps your secrets away from every other job, such as your build, which compiles third-party code.
- **A second one**, as in the workflow below, also keeps the key away from the publish job, which runs rclone.
- **A rule that only allows tags** stops workflows on branches and pull requests, but anyone with write access can still push a tag.
- **Required reviewers** make each release wait for your approval. On `release-signing` alone, that's one approval per release.

On AWS, you can [use OIDC](#publishing-to-aws-with-oidc) instead of the two S3 secrets and `S3_ENDPOINT`.

### Workflow

This is a separate release workflow that builds again on each tag. To keep one workflow, add these jobs to it as in the [Quick start](#3-add-the-jobs). Replace `<commit-sha>` with the commit of a release, because the action handles your signing key.

```yaml
on:
  push:
    tags: ['v*']

permissions:
  contents: read

jobs:
  build:
    uses: duckdb/extension-ci-tools/.github/workflows/_extension_distribution.yml@v2.0-cyanoptera
    with:
      duckdb_version: v2.0.0
      ci_tools_version: v2.0-cyanoptera
      extension_name: my_ext

  sign:
    needs: build
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    environment: release-signing
    outputs:
      bundle-digest: ${{ steps.sign.outputs.bundle-digest }}
      verify-runners: ${{ steps.sign.outputs.verify-runners }}
    steps:
      - id: sign
        uses: tobilg/duckdb-extension-self-hosting@<commit-sha> # v1.0.0
        with:
          mode: sign
          extension-name: my_ext
          signing-key: ${{ secrets.EXTENSION_SIGNING_KEY }}
          additional-public-keys: ${{ vars.EXTENSION_RESERVE_PUBLIC_KEY }}

  verify:
    needs: sign
    strategy:
      fail-fast: false
      matrix:
        os: ${{ fromJSON(needs.sign.outputs.verify-runners) }}
    runs-on: ${{ matrix.os }}
    timeout-minutes: 30
    permissions: {}
    steps:
      - uses: tobilg/duckdb-extension-self-hosting@<commit-sha> # v1.0.0
        with:
          mode: verify

  publish:
    needs: [sign, verify]
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    environment: release-storage
    concurrency:
      group: publish-my_ext
      cancel-in-progress: false
    steps:
      - uses: tobilg/duckdb-extension-self-hosting@<commit-sha> # v1.0.0
        with:
          mode: publish
          bundle-digest: ${{ needs.sign.outputs.bundle-digest }}
          s3-endpoint: ${{ secrets.S3_ENDPOINT }}
          s3-bucket: my-extensions
          s3-access-key-id: ${{ secrets.S3_ACCESS_KEY_ID }}
          s3-secret-access-key: ${{ secrets.S3_SECRET_ACCESS_KEY }}
          repository-url: https://extensions.example.com
```

One Linux job signs and publishes the binaries of every platform. `verify` gets one runner for each platform that was built and has one, and you choose the platforms on the `build` job: see [Choosing platforms](#choosing-platforms).

### Pinning the key

The Quick start's `CREATE` reads the keys from your bucket's key file, pins them and never fetches them again. It prints each one as `sha256:<hex>`, so compare those with the [fingerprints you published](#signing-keys). That comparison is what catches a swapped key file: whoever can write to your bucket when a new client runs `CREATE` can get their own key pinned, and that client would then load their builds. Clients that pinned earlier aren't affected.

Clients can pass the key inline instead, which needs no comparison, because a build signed with another key is refused. [DuckDB-Wasm](#duckdb-wasm) needs this form. The job summary of the publish job has it filled in, with every key you list:

```sql
CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo
    WITH PREFIX 'https://extensions.example.com'
    USING PUBLIC KEY '-----BEGIN PUBLIC KEY----- ...';
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | required | `sign`, `verify` or `publish`. `verify` refuses to share a job with the other two. |
| `signed-artifact` | `duckdb-extension-signed` | Workflow artifact that takes the signed tree to the later jobs. Change it if a run signs more than once. |

For `mode: sign`:

| Input | Default | Description |
| --- | --- | --- |
| `signing-key` | required | RSA-2048 private key in PEM format, not encrypted. No other mode accepts it. |
| `extension-name` | | Extension to sign. Selects the artifacts, and skips other extensions found in them. Required unless `all-extensions` is set. |
| `all-extensions` | `false` | Sign every extension found. Off by default, because a build tree holds more than the one being released. |
| `artifact-pattern` | `<extension-name>-*-extension-*` | Glob for the workflow artifacts to download |
| `path` | | Directory that already holds the binaries, for other build systems. Nothing is downloaded. |
| `exclude-platforms` | | Comma or space separated platforms to skip. Takes `*` and `?`, such as `wasm_*`. A name that can't be a platform fails the run, and an entry that matches nothing gets a warning. |
| `verify-runner-labels` | | JSON object that replaces the runner for a platform in `verify-runners`, such as `{"osx_arm64": "my-mac-runner"}`. Takes one label each, and only platforms that have a runner. |
| `duckdb-version` | from the footer | DuckDB version directory with its leading `v`, such as `v2.0.0`, or a comma separated list. Only required for `C_STRUCT` builds. |
| `extension-version` | from the footer | Version in the versioned path. Also stands in for a footer without a usable version. `duckdb_extensions()` still reports the footer's version, so the run warns if they differ. |
| `additional-public-keys` | | Further public keys for the key file, such as your reserve key |
| `upload-latest` | `true` | Include the path `INSTALL` reads |
| `upload-versioned` | `true` | Include the path `INSTALL ... VERSION` reads |
| `publish-key-file` | `true` | Include `.well-known/duckdb-extension-repo.json`, which `CREATE` reads when a client [doesn't pass a key](#pinning-the-key) |

For `mode: verify`:

| Input | Default | Description |
| --- | --- | --- |
| `smoke-test-setup-sql` | | SQL to run first in the smoke test, such as loading an extension yours depends on |

For `mode: publish`:

| Input | Default | Description |
| --- | --- | --- |
| `bundle-digest` | required | The output of the same name from the sign job. A signed tree that changed since is refused. |
| `s3-bucket` | required | Bucket to publish to |
| `s3-prefix` | | Key prefix inside the bucket |
| `s3-endpoint` | AWS | S3 API endpoint. Use `https://`: plain `http://` gets a warning, and rclone's AWS provider refuses to upload over it. |
| `s3-region` | `auto` on R2, `AWS_REGION` elsewhere | Bucket region |
| `s3-provider` | detected | [rclone provider](https://rclone.org/s3/) |
| `s3-access-key-id`, `s3-secret-access-key`, `s3-session-token` | `AWS_*` variables | Credentials. Set the key ID and secret together. Setting them ignores any `AWS_SESSION_TOKEN` in the environment. Leave them out to use a [role through OIDC](#publishing-to-aws-with-oidc). |
| `overwrite-versioned` | `false` | Allow replacing a versioned object with different bytes |
| `allow-key-change` | `false` | Allow a signing key that isn't in the bucket's key file, for a [rotation](#rotating-keys) |
| `allow-downgrade` | `false` | Allow moving the latest path to a lower version |
| `repository-url` | `s3://<bucket>/<prefix>` | Public prefix clients use |
| `check-repository` | `true` | Read every object back through `repository-url` and compare the bytes |

## Outputs

| Output | Description |
| --- | --- |
| `fingerprint` | Fingerprint of the signing key, in the format DuckDB reports it |
| `signed-dir` | Directory with the signed files, laid out like the repository |
| `bundle-digest` | Digest of the signed tree, for the publish job. Set by the sign job. |
| `verify-runners` | JSON array for the matrix of the verify job, with one runner for each platform in the signed tree that has one. Never empty: a release with none falls back to `ubuntu-24.04`, which skips the test with a notice. Set by the sign job. |
| `files` | JSON array with platform, versions, ABI and object path of each file, the SHA-256 of the object (`sha256`) and of the binary inside it (`binary_sha256`) |
| `uploaded-objects` | JSON array of the object paths this run uploaded or confirmed. Shorter than `files` if an upload failed partway. Set by the publish job. |
| `repository-url` | Prefix for `CREATE EXTENSION REPOSITORY`. Set by the publish job. |

## What ends up in the bucket

```text
.well-known/duckdb-extension-repo.json
<duckdb_version>/<platform>/<name>.duckdb_extension.gz
<name>/<extension_version>/<duckdb_version>/<platform>/<name>.duckdb_extension.gz
<duckdb_version>/wasm_<target>/<name>.duckdb_extension.wasm
```

Platform and versions come from the footer of each binary, not from the artifact name, so any build system works. The file name gives the extension's name, which can only have lowercase letters, digits and underscores, and can't start with a digit. DuckDB lowercases the name when it requests the file, and looks up C symbols named after it to load the extension.

A new DuckDB release means new objects, depending on the ABI type:

- **`CPP` and `C_STRUCT_UNSTABLE`** builds only load in the exact DuckDB version they were built for, so rebuild them for each release.
- **`C_STRUCT`** builds against the stable C API can be loaded by later versions. List every version in `duckdb-version`, and the same signed binary is published to each directory.

## Choosing platforms

Set them on the `build` job, with upstream's `exclude_archs` and `opt_in_archs`, separated by `;`. Community extensions set the same lists in their `description.yml`.

```yaml
build:
  uses: duckdb/extension-ci-tools/.github/workflows/_extension_distribution.yml@v2.0-cyanoptera
  with:
    duckdb_version: v2.0.0
    ci_tools_version: v2.0-cyanoptera
    extension_name: my_ext
    exclude_archs: 'wasm_mvp;wasm_eh;wasm_threads'
    opt_in_archs: 'osx_amd64'
```

The later jobs follow what was really built. `sign` reads the platform from each binary's footer, and its `verify-runners` output gives `verify` the runner for each platform:

| Platform | Built by default | Upstream's tests, unsigned | `verify`, signed |
| --- | --- | --- | --- |
| `linux_amd64` | Yes | Yes | `ubuntu-24.04` |
| `linux_arm64` | Yes | No | `ubuntu-24.04-arm` |
| `osx_arm64` (Apple Silicon) | Yes | Yes | `macos-26` |
| `osx_amd64` (Intel) | No | No | `macos-26-intel` |
| `windows_amd64`, `windows_amd64_mingw` | Yes | Yes | None |
| `windows_arm64` | No | Yes | None |
| `linux_amd64_musl`, `linux_arm64_musl` | No | Yes | None |
| `wasm_mvp`, `wasm_eh`, `wasm_threads` | Yes | No | None |

Upstream's tests are your extension's own SQL tests, run in the build job as of `v2.0-cyanoptera`, and `skip_tests` turns them off. `verify` has no runner for the rest: this action doesn't run on Windows, GitHub has no musl runners, and Wasm has [its own notes](#duckdb-wasm). The job summary lists those builds. They're still signed and published, so test them yourself or leave them out.

- **Leave out a build without rebuilding:** set `exclude-platforms` on the sign job, and `verify-runners` follows it.
- **Other runners:** set `verify-runner-labels` on the sign job, for a self-hosted runner, or for a newer image before this action moves to it.
- **A matrix by hand:** this still works, but nothing warns you if it misses a platform.
- **`allow_failure_archs`:** a failed build just isn't in the signed tree. The release goes out without that platform, and its latest path keeps the previous build.

## What stops a release

Each of these fails the run before anything is uploaded:

- **A build that doesn't load.** The verify jobs run first, and `publish` has `needs` on them. A failure there leaves the bucket as it was, so `latest` keeps working and the version number stays free for a fixed build. This only covers [the platforms `verify` has a runner for](#choosing-platforms).
- **A signed tree that changed.** `bundle-digest` comes from the sign job through GitHub's job outputs, which the verify job can't touch.
- **A signing key clients don't know.** If the bucket has a key file and doesn't list the signing key, clients that pinned those keys would reject the release. This catches a wrong secret. A rotation sets `allow-key-change`.
- **A lower version on the latest path.** This catches an older tag re-run after a newer one. It compares major.minor.patch with what's live, and only leaves a notice if a version isn't in that form, like a commit hash. Deliberate rollbacks set `allow-downgrade`.
- **Different bytes for a published version.** Rebuilding produces different bytes, so re-running a release with new builds hits this. Re-running only the failed job is safe, because it uses the same signed tree. So is signing the same build again, which gives the same bytes.

After the upload, the publish job reads every object and the key file back through `repository-url`, for all platforms. A failure there means a wrong URL or a CDN serving an older object. These objects are already live at that point, and the job summary says so.

If the upload itself fails partway, the summary and `uploaded-objects` list what went live. Re-run the job to finish it.

Two publish jobs at the same time can still get past the version check, because it isn't atomic on S3. That's why the workflow above has a `concurrency` group: use one for every extension.

## Publishing to AWS with OIDC

On AWS, the publish job can assume an IAM role through GitHub's OIDC provider, so that no storage keys are kept in GitHub. This is optional: the keys from the [Quick start](#2-add-the-secrets) keep working, and the other two jobs don't change. It only works on AWS, because Cloudflare R2 doesn't accept AWS roles.

> **Status:** tested with the credentials this produces against a local store, but not yet against real AWS.

First, create an [IAM identity provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html) in your account, with the URL `https://token.actions.githubusercontent.com` and the audience `sts.amazonaws.com`.

Then create a role that trusts it. The subject limits the role to the publish job, because a job only gets `environment:release-storage` in its token if it runs in that environment:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account_id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "<subject>"
        }
      }
    }
  ]
}
```

The subject depends on [the repository that runs the workflow](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/):

| Repository | Subject |
| --- | --- |
| Created on or after 15 July 2026, opted in, or renamed or transferred since | `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:release-storage` |
| Any other | `repo:<owner>/<repo>:environment:release-storage` |

The wrong form fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. To see what your job really gets, follow AWS's [token inspection steps](https://github.com/aws-actions/configure-aws-credentials/blob/v6.3.0/README.md#inspecting-the-token).

Give the role access to the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::my-extensions/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::my-extensions"
    }
  ]
}
```

In the workflow, only the publish job changes. It assumes the role first, and leaves out the S3 keys and the endpoint. [`examples/release-aws-oidc.yml`](examples/release-aws-oidc.yml) has the complete workflow.

```yaml
publish:
  needs: [sign, verify]
  runs-on: ubuntu-24.04
  timeout-minutes: 30
  environment: release-storage
  permissions:
    contents: read
    id-token: write
  concurrency:
    group: publish-my_ext
    cancel-in-progress: false
  steps:
    - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
      with:
        role-to-assume: arn:aws:iam::<account_id>:role/extension-publisher
        aws-region: <bucket-region>
    - uses: tobilg/duckdb-extension-self-hosting@<commit-sha> # v1.0.0
      with:
        mode: publish
        bundle-digest: ${{ needs.sign.outputs.bundle-digest }}
        s3-bucket: my-extensions
        repository-url: https://extensions.example.com
```

- **Only this job gets `id-token: write`.** Don't set it for the whole workflow: `verify` refuses to run with it, because your extension's code could use it to assume the role.
- **Credentials last 1 hour by default, and don't refresh.** A publish that takes longer fails partway, and the summary lists what went live. Set `role-duration-seconds` on AWS's action to extend it.

## Serving the bucket

Clients only send `HEAD` and `GET`, so a public bucket can be served from any HTTPS endpoint. Clients reject anything not signed by a key they pinned, so the bucket doesn't have to be trusted after that. The exception is pinning itself: a first `CREATE` without a key trusts the key file, unless the client [compares the fingerprints or passes the key inline](#pinning-the-key).

| Prefix | Bucket | Clients need |
| --- | --- | --- |
| `https://extensions.example.com` | Public | httpfs, which DuckDB autoinstalls from its core repository |
| `s3://my-bucket` | Private | httpfs, plus a `CREATE SECRET (TYPE s3, ...)` for `INSTALL` |
| `http://extensions.example.com` | Public | Nothing extra with an inline key, but only until something loads httpfs: from then on DuckDB requests `https://` instead. DuckDB also doesn't follow redirects here, so an HTTP-to-HTTPS redirect breaks it. |

On Cloudflare R2, use a custom domain. Cloudflare says public access through `r2.dev` ["is rate-limited and should only be used for development purposes"](https://developers.cloudflare.com/r2/buckets/public-buckets/).

Custom domains go through Cloudflare's cache, which [keeps `.gz` files for 2 hours by default](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/). The latest paths keep their names between releases, so the action stores `Cache-Control: no-cache` on them and on the key file, and `public, max-age=86400` on versioned objects. A Cache Rule of your own can override that. If a client could still get an old copy, the check after the upload fails with a "different build" error, and you can purge the path. After `overwrite-versioned`, purge the versioned path too.

## Security

- **Pin the action by commit.** It handles your signing key: `uses: tobilg/duckdb-extension-self-hosting@<sha> # v1.0.0`.
- **Limit who can reach the key.** Use an environment with required reviewers, and only run the job on tags.
- **Why three jobs.** The runner keeps a job's secrets in its own memory for the whole job, and code running in that job can read them there, as the [tj-actions compromise](https://www.cve.org/CVERecord?id=CVE-2025-30066) did. A clean environment for the DuckDB CLI doesn't change that, so a build that's compromised upstream could steal a signing key from any job that loads it, and a key can't be revoked. So `verify` refuses to run in a job that signed or published, and refuses the key, S3 credentials, `AWS_*` credentials and `id-token: write` in its job. It can't see other secrets you add to that job, so don't. With [OIDC](#publishing-to-aws-with-oidc), limiting the role's subject to the publish job's environment is a second layer: a token from another job doesn't match it.
- **What the action does with the key.** It goes through the signing step's environment into a `0600` file, after the artifacts are downloaded. The file is deleted as soon as the last binary is signed, before compressing, and a final step removes it if the run was killed before that. It's never passed to rclone, and tracing is never turned on.
- **What the verify job can reach.** It runs your extension's native code with only `PATH`, `HOME`, `TMPDIR`, and the proxy and CA variables in the CLI's environment. Set `permissions: {}` on it, because it needs no `GITHUB_TOKEN`. It can reach the workflow run's artifacts, but anything it changes fails the `bundle-digest` check, and it can't sign anything.
- **What it downloads.** rclone is pinned and checked against hashes stored in this repository. The verify job gets the DuckDB CLI for each published version from DuckDB's GitHub releases, over HTTPS only and without a hash check, because the version comes from your build. No `curl | bash`.
- **Published versions don't change.** Replacing a versioned object with different bytes fails unless you set `overwrite-versioned`.

What signing can't do, whichever tool you use:

- **Trust on first use.** Without `USING PUBLIC KEY`, clients trust whoever can write to the key file at that moment. Pass the key inline, or publish the fingerprint elsewhere and [have clients compare it](#pinning-the-key).
- **No revocation or expiry.** A leaked key stays trusted until each client replaces its pin.
- **No rollback protection.** Signatures carry no timestamp, so anyone who can write to the bucket can serve an older, validly signed build.
- **No sandbox.** Extensions are native code with the privileges of the DuckDB process.

## Rotating keys

Keys only change when a client creates the repository again:

1. On each client, pin both keys with `CREATE OR REPLACE EXTENSION REPOSITORY ... USING PUBLIC KEYS '<old>', '<new>'`. Skip this if you pinned your reserve key from the start.
2. Publish with the new `signing-key`, and list the old public key in `additional-public-keys` on the sign job. Set `allow-key-change: true` on the publish job, unless the new key is already in the bucket's key file as your reserve key. Set `overwrite-versioned: true` too if you re-sign an existing version.
3. On each client, run `FORCE INSTALL` for the installed extensions.
4. On each client, remove the old key with another `CREATE OR REPLACE`.

Removing a key makes builds signed with it fail on the next `LOAD`, so finish step 3 first.

## DuckDB-Wasm

**Experimental.** Wasm builds are signed and published automatically unless you exclude them. They need `brotli` on the runner, which `ubuntu-24.04` has. They get the latest path only, with `Content-Encoding: br` and `Content-Type: application/wasm`.

The tests load the action's output in headless Chrome with DuckDB-Wasm `1.33.1-dev110.0`. That covers `C_STRUCT` and `CPP` builds, and rejection of wrong keys, tampered files, bare `LOAD`, `custom_extension_repository` and direct URLs. Three things are different from native DuckDB:

- **No stable release yet.** The tested build is a dev build of the v2.0.0 commit, so it requests `<prefix>/d54cbbe3df/wasm_eh/...` rather than `v2.0.0/`. A stable DuckDB-Wasm 2.0 should request `v2.0.0/`, where DuckDB's own repository serves these files today. To test against the dev build now, set `duckdb-version: d54cbbe3df`.
- **The bucket needs CORS** that allows `GET` from your site's origin, or the fetch fails. The verify job can't cover Wasm, so check this yourself.
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
bash tests/e2e.sh         # SeaweedFS in Docker, real extensions, real DuckDB CLI
bash tests/wasm/run.sh    # DuckDB-Wasm in headless Chrome, needs Node.js
bash tests/rclone-pin.sh  # checks the rclone pin, or moves it: bash tests/rclone-pin.sh v1.76.0
```

Scripts must keep running on bash 3.2, the stock bash on macOS. The behavior this action relies on is in [DuckDB](https://github.com/duckdb/duckdb)'s `extension_repository_manager.cpp` and `extension_install_dynamic.cpp`, [`duckdb-web`](https://github.com/duckdb/duckdb-web)'s `extension_repositories.md`, and [`duckdb-wasm`](https://github.com/duckdb/duckdb-wasm).

`.github/workflows/aws-oidc-check.yml` runs the OIDC route against real AWS. It only runs by hand, and needs a test bucket, a [role](#publishing-to-aws-with-oidc) whose subject names the environment `aws-oidc-check`, and the variables `AWS_CHECK_ROLE_ARN`, `AWS_CHECK_REGION` and `AWS_CHECK_BUCKET`. It writes to `ci/<run_id>`, and the role can't delete, so expire that prefix with a lifecycle rule.

The tests download real extensions and check them against `tests/fixtures.sha256`. A hash mismatch means that the file changed on DuckDB's servers, not that this project broke. Dependabot keeps the pinned actions and the Wasm test's packages up to date.

## License

[MIT](LICENSE). `scripts/compute-extension-hash.sh` is copied unchanged from DuckDB, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
