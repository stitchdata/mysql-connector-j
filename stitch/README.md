# Stitch security fork of MySQL Connector/J

This is a fork of MySQL Connector/J carrying a single security fix, published to
our private maven repo for consumption by `loader-mysql` (and any other service
that loads into customer MySQL warehouses).

## Why this fork exists

**CVE: rogue-MySQL `LOAD DATA LOCAL INFILE` arbitrary file read.**

Upstream Connector/J, when connected with `allowLoadLocalInfile=true`, will
honor a `LOCAL INFILE` request from the *server* for an arbitrary path — reading
that file off the client's own filesystem and uploading it. Because a Stitch
customer can create a MySQL *destination* pointing at a server they control, an
attacker's rogue MySQL server can respond to the loader's first query with a
`LOCAL INFILE` request for e.g. `/proc/self/environ` and exfiltrate the loader
worker's environment (production credentials, tokens, the internal service map).

We cannot simply set `allowLoadLocalInfile=false`: the loader legitimately needs
LOCAL INFILE to stream S3 data into the warehouse via an **in-memory** stream
(`setLocalInfileInputStream` + `LOAD DATA LOCAL INFILE ''`).

## The fix

Patched file:

    src/main/protocol-impl/java/com/mysql/cj/protocol/a/NativeProtocol.java

`getFileStream(...)` now **only ever returns the in-memory hooked stream** that
the client installs via `setLocalInfileInputStream`. It never opens a
server-named file. If no hooked stream is set, it throws
`MysqlIO.LoadDataLocalInfileNoStream` (a new key in
`src/main/resources/com/mysql/cj/LocalizedErrorMessages.properties`), refusing
to read a local file.

Since our loaders always load via the in-memory stream, this is
behaviour-preserving for us while fully closing the file-read vector. The driver
catches the exception, sends the empty-file EOF packet to keep the protocol in
sync, and the load fails loudly with no data leaked.

## Coordinates

    com.mysql/mysql-connector-j "8.0.33-stitch-1"

- Base: upstream `8.0.33`
- `-stitch-N` suffix is bumped for each new patched release.

## Building

```
stitch/build-jar.sh
```

Produces `stitch/target/mysql-connector-j-8.0.33-stitch-1.jar` and a matching
`.pom`. Rather than running the (heavy) full Ant build, this downloads the
published upstream base jar, recompiles only the patched class from this fork's
source, overlays it, and refreshes the localized error-message bundle — so the
result is byte-for-byte upstream except for our security fix. It also verifies
the fix is present in the assembled jar (message key present, no
`FileInputStream` reference left in `NativeProtocol`).

Override `BASE_VERSION` / `OUT_VERSION` via environment variables when cutting a
new base or a new `-stitch-N`.

## Publishing to our maven repo

```
aws sso login            # ensure valid AWS SSO credentials
stitch/deploy-jar.sh     # builds, then `lein deploy` to the private repo
```

This publishes to `s3p://com-stitchdata-prod-maven-repository/releases` using
`s3-wagon-private` with `:no-auth true`. Because that wagon uses the AWS Java
SDK v1 (which cannot read the SSO token cache), `deploy-jar.sh` first exports
your active profile's temporary SSO credentials into `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` (via
`aws configure export-credentials`). Env-var credentials take precedence over
the SDK's credentials-file lookup, so a stale static `[default]` key in
`~/.aws/credentials` won't shadow your SSO session. Set `AWS_PROFILE` if your
deploy role lives in a non-default profile. Set `REPO=snapshots` to push to the
snapshots repo instead.

## Consuming it

Services depend on it normally, e.g. in `loader-mysql/project.clj`:

```clojure
[com.mysql/mysql-connector-j "8.0.33-stitch-1"]
```

To ship a new patched build: bump `OUT_VERSION` here, `deploy-jar.sh`, then bump
the dependency version in the consuming service.
