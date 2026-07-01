#!/usr/bin/env bash
#
# build-jar.sh
#
# Build the Stitch security-patched MySQL Connector/J jar (+ matching POM) from
# THIS fork's source and drop it into stitch/target/.
#
# WHY THIS FORK EXISTS
# --------------------
# CVE: rogue-MySQL "LOAD DATA LOCAL INFILE" arbitrary file read. A MySQL
# destination pointing at an attacker-controlled server can ask the Java loader
# (Connector/J, allowLoadLocalInfile=true) to upload arbitrary files from the
# loader's own filesystem (e.g. /proc/self/environ).
#
# THE FIX (already committed in this fork)
# ----------------------------------------
#   src/main/protocol-impl/java/com/mysql/cj/protocol/a/NativeProtocol.java
#     getFileStream(...) now ONLY ever returns the in-memory hooked stream that
#     the client installs (setLocalInfileInputStream). It never opens a
#     server-named file; if no stream is set it throws
#     (MysqlIO.LoadDataLocalInfileNoStream), refusing to read a local file.
#
# BUILD STRATEGY
# --------------
# A full Ant build of Connector/J is heavy and needs the whole upstream
# toolchain. Instead we take the published upstream base jar (identical bytes
# for every class except the one we patched), recompile ONLY the patched class
# from this fork's source, overlay it, and refresh the localized error-message
# bundle. The result is byte-for-byte upstream except for our security fix.
#
# Output coordinate: com.mysql:mysql-connector-j:8.0.33-stitch-1
#
# Requirements: curl, javac/jar (JDK 8+), unzip.
#
set -euo pipefail

BASE_VERSION="${BASE_VERSION:-8.0.33}"
OUT_VERSION="${OUT_VERSION:-8.0.33-stitch-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_DIR="${SCRIPT_DIR}/target"

GROUP_PATH="com/mysql/mysql-connector-j"
CENTRAL="https://repo1.maven.org/maven2/${GROUP_PATH}/${BASE_VERSION}"

PATCHED_JAVA="${FORK_ROOT}/src/main/protocol-impl/java/com/mysql/cj/protocol/a/NativeProtocol.java"
PATCHED_PROPS="${FORK_ROOT}/src/main/resources/com/mysql/cj/LocalizedErrorMessages.properties"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo ">> Building com.mysql:mysql-connector-j:${OUT_VERSION} (base ${BASE_VERSION})"

# --- 0. Sanity: the fix must be present in the source we're building --------
for f in "${PATCHED_JAVA}" "${PATCHED_PROPS}"; do
  [[ -f "${f}" ]] || { echo "ERROR: missing ${f}" >&2; exit 1; }
done
grep -q "LoadDataLocalInfileNoStream" "${PATCHED_JAVA}" \
  || { echo "ERROR: getFileStream fix not found in NativeProtocol.java" >&2; exit 1; }
grep -q "^MysqlIO.LoadDataLocalInfileNoStream=" "${PATCHED_PROPS}" \
  || { echo "ERROR: message key missing from LocalizedErrorMessages.properties" >&2; exit 1; }

# --- 1. Download upstream base jar + pom ------------------------------------
BASE_JAR="${WORK}/base.jar"
BASE_POM="${WORK}/base.pom"
echo ">> Downloading upstream base artifacts from Maven Central"
curl -fsSL "${CENTRAL}/mysql-connector-j-${BASE_VERSION}.jar" -o "${BASE_JAR}"
curl -fsSL "${CENTRAL}/mysql-connector-j-${BASE_VERSION}.pom" -o "${BASE_POM}"

# --- 2. Compile the patched class against the base jar ----------------------
echo ">> Compiling patched NativeProtocol.java"
CLASSES="${WORK}/classes"
mkdir -p "${CLASSES}"
javac --release 8 -encoding UTF-8 -cp "${BASE_JAR}" -d "${CLASSES}" "${PATCHED_JAVA}"

# --- 3. Assemble the patched jar --------------------------------------------
echo ">> Assembling patched jar"
OUT_JAR="${WORK}/mysql-connector-j-${OUT_VERSION}.jar"
cp "${BASE_JAR}" "${OUT_JAR}"
( cd "${CLASSES}" && jar uf "${OUT_JAR}" com/mysql/cj/protocol/a/NativeProtocol*.class )
( cd "${FORK_ROOT}/src/main/resources" && jar uf "${OUT_JAR}" com/mysql/cj/LocalizedErrorMessages.properties )

# --- 4. Verify the fix made it in (extract to files: `grep -q` on a pipe
#        under `set -o pipefail` fails via SIGPIPE) -------------------------
unzip -p "${OUT_JAR}" com/mysql/cj/LocalizedErrorMessages.properties > "${WORK}/props.out"
grep -q "LoadDataLocalInfileNoStream" "${WORK}/props.out" \
  || { echo "ERROR: message key not present in assembled jar" >&2; exit 1; }
javap -p -c -classpath "${OUT_JAR}" com.mysql.cj.protocol.a.NativeProtocol > "${WORK}/nativeprotocol.txt"
if grep -q "FileInputStream" "${WORK}/nativeprotocol.txt"; then
  echo "ERROR: assembled NativeProtocol still references FileInputStream" >&2
  exit 1
fi

# --- 5. Generate the matching POM (upstream pom, project version rewritten) --
echo ">> Generating POM"
OUT_POM="${WORK}/mysql-connector-j-${OUT_VERSION}.pom"
# Only the project <version> sits at 2-space indent; dependency versions are
# deeper, so this targeted substitution leaves transitive deps untouched.
sed "s|^  <version>${BASE_VERSION}</version>|  <version>${OUT_VERSION}</version>|" \
  "${BASE_POM}" > "${OUT_POM}"

# --- 6. Publish into stitch/target/ -----------------------------------------
mkdir -p "${TARGET_DIR}"
cp "${OUT_JAR}" "${TARGET_DIR}/mysql-connector-j-${OUT_VERSION}.jar"
cp "${OUT_POM}" "${TARGET_DIR}/mysql-connector-j-${OUT_VERSION}.pom"

echo ">> Done:"
ls -l "${TARGET_DIR}"
