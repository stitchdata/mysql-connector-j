#!/usr/bin/env bash
#
# deploy-jar.sh
#
# Build the Stitch security-patched Connector/J jar and publish it to our
# private maven repo so services (e.g. loader-mysql) can depend on
#
#     com.mysql/mysql-connector-j "8.0.33-stitch-1"
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

OUT_VERSION="${OUT_VERSION:-8.0.33-stitch-1}"
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

# --- 2. Publish via lein + s3-wagon-private (AWS SSO) -----------------------
echo ">> Deploying ${GROUP_ARTIFACT} ${OUT_VERSION} to '${REPO}'"
cd "${SCRIPT_DIR}"
lein deploy "${REPO}" "${GROUP_ARTIFACT}" "${OUT_VERSION}" "${JAR}" "${POM}"

echo ">> Published ${GROUP_ARTIFACT} ${OUT_VERSION}."
