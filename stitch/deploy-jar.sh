#!/usr/bin/env bash
#
# deploy-jar.sh
#
# Build the Stitch security-patched Connector/J jar and publish it to our
# private maven repo so services (e.g. loader-mysql) can depend on
#
#     com.mysql/mysql-connector-j "8.0.33-stitch-2"
#
# like any other internal artifact.
#
# We reuse leiningen + s3-wagon-private (with :no-auth true so it uses ambient
# AWS SSO credentials, matching our other services). The minimal deploy project
# lives in stitch/project.clj; `lein deploy` with explicit coordinates uploads
# the prebuilt jar/pom without building anything itself.
#
# Publishes to the "releases" repo by default. Requires valid AWS SSO creds in
# the environment (e.g. `aws sso login` first).
#
# Requirements: everything build-jar.sh needs, plus `lein`.
#
set -euo pipefail

OUT_VERSION="${OUT_VERSION:-8.0.33-stitch-2}"
REPO="${REPO:-releases}"          # "releases" or "snapshots"
GROUP_ARTIFACT="com.mysql/mysql-connector-j"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${SCRIPT_DIR}/target"
JAR="${TARGET_DIR}/mysql-connector-j-${OUT_VERSION}.jar"
POM="${TARGET_DIR}/mysql-connector-j-${OUT_VERSION}.pom"

# --- 1. Build the artifact ---------------------------------------------------
"${SCRIPT_DIR}/build-jar.sh"

[[ -f "${JAR}" && -f "${POM}" ]] \
  || { echo "ERROR: expected artifacts not found in ${TARGET_DIR}" >&2; exit 1; }

# --- 2. Bridge AWS SSO -> env creds for the JVM -----------------------------
# s3-wagon-private uses the AWS Java SDK v1, whose default credential provider
# chain CANNOT read the SSO token cache. If you only have an SSO session, the
# JVM falls back to any static keys in ~/.aws/credentials (often a stale
# [default] entry) and the deploy fails with:
#     "The AWS Access Key Id you provided does not exist" (403 InvalidAccessKeyId)
# Export the active profile's *temporary* SSO credentials into env vars, which
# take precedence over the credentials file in the SDK chain. Skip if the caller
# already provided credentials in the environment.
if [[ -z "${AWS_SESSION_TOKEN:-}" && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  echo ">> Exporting SSO credentials for profile '${AWS_PROFILE:-default}' into the environment"
  if ! creds="$(aws configure export-credentials \
                  --profile "${AWS_PROFILE:-default}" --format env 2>/dev/null)"; then
    echo "ERROR: could not export AWS credentials. Run 'aws sso login' first" >&2
    echo "       (and ensure AWS CLI v2 supports 'configure export-credentials')." >&2
    exit 1
  fi
  eval "${creds}"
fi

# --- 3. Publish via lein + s3-wagon-private ---------------------------------
echo ">> Deploying ${GROUP_ARTIFACT} ${OUT_VERSION} to '${REPO}'"
cd "${SCRIPT_DIR}"
lein deploy "${REPO}" "${GROUP_ARTIFACT}" "${OUT_VERSION}" "${JAR}" "${POM}"

echo ">> Published ${GROUP_ARTIFACT} ${OUT_VERSION}."
