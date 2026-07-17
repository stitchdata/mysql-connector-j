#!/usr/bin/env bash
#
# build-jar.sh
#
# Build the Stitch security-patched MySQL Connector/J jar (+ matching POM) from
# THIS fork's source and drop it into stitch/target/.
#
# WHY THIS FORK EXISTS
# --------------------
# Two orthogonal rogue-MySQL CVEs, both reachable when a MySQL destination
# points the Java loader at an attacker-controlled server:
#
#   SAC-31461  "LOAD DATA LOCAL INFILE" arbitrary file read. The server asks the
#              loader (Connector/J, allowLoadLocalInfile=true) to upload an
#              arbitrary file from the loader's own filesystem (/proc/self/environ).
#
#   SAC-31683  BLOB deserialization RCE. With autoDeserialize=true (injectable via
#              the JDBC URL), ResultSetImpl.getObject() ran ObjectInputStream
#              .readObject() on server-supplied BLOB bytes. With Clojure on the
#              classpath this is a gadget chain to remote code execution.
#
# THE FIX (already committed in this fork)
# ----------------------------------------
#   src/main/protocol-impl/java/com/mysql/cj/protocol/a/NativeProtocol.java
#     getFileStream(...) now ONLY ever returns the in-memory hooked stream that
#     the client installs (setLocalInfileInputStream). It never opens a
#     server-named file; if no stream is set it throws
#     (MysqlIO.LoadDataLocalInfileNoStream), refusing to read a local file.
#
#   src/main/user-impl/java/com/mysql/cj/jdbc/result/ResultSetImpl.java
#     getObject() no longer deserializes BLOB/BIT values. The ObjectInputStream
#     .readObject() sink is removed entirely (absent from the compiled bytecode);
#     raw bytes are always returned, and if a serialized-object stream is seen
#     while autoDeserialize is on it throws an explicit sentinel SQLException
#     ("Refusing to deserialize object stream from BLOB value...").
#
# BUILD STRATEGY
# --------------
# A full Ant build of Connector/J is heavy and needs the whole upstream
# toolchain. Instead we take the published upstream base jar (identical bytes
# for every class except the ones we patched), recompile ONLY the patched
# classes from this fork's source, overlay them, and refresh the localized
# error-message bundle. The result is byte-for-byte upstream except for our
# security fixes.
#
# Output coordinate: com.mysql:mysql-connector-j:8.0.33-stitch-2
#
# Requirements: curl, javac/jar (JDK 8+), unzip.
#
set -euo pipefail

BASE_VERSION="${BASE_VERSION:-8.0.33}"
OUT_VERSION="${OUT_VERSION:-8.0.33-stitch-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_DIR="${SCRIPT_DIR}/target"

GROUP_PATH="com/mysql/mysql-connector-j"
CENTRAL="https://repo1.maven.org/maven2/${GROUP_PATH}/${BASE_VERSION}"

PATCHED_JAVA="${FORK_ROOT}/src/main/protocol-impl/java/com/mysql/cj/protocol/a/NativeProtocol.java"
PATCHED_RESULTSET="${FORK_ROOT}/src/main/user-impl/java/com/mysql/cj/jdbc/result/ResultSetImpl.java"
PATCHED_PROPS="${FORK_ROOT}/src/main/resources/com/mysql/cj/LocalizedErrorMessages.properties"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo ">> Building com.mysql:mysql-connector-j:${OUT_VERSION} (base ${BASE_VERSION})"

# --- 0. Sanity: the fix must be present in the source we're building --------
for f in "${PATCHED_JAVA}" "${PATCHED_RESULTSET}" "${PATCHED_PROPS}"; do
  [[ -f "${f}" ]] || { echo "ERROR: missing ${f}" >&2; exit 1; }
done
# Security invariants of the LOCAL INFILE fix (SAC-31461), independent of which
# exception style is used:
#   1. getFileStream must feed the in-memory hooked stream...
grep -q "getLocalInfileInputStream" "${PATCHED_JAVA}" \
  || { echo "ERROR: getFileStream fix not found in NativeProtocol.java (no getLocalInfileInputStream call)" >&2; exit 1; }
#   2. ...and must never open a server-named file.
if grep -q "new FileInputStream" "${PATCHED_JAVA}"; then
  echo "ERROR: NativeProtocol.java still constructs a FileInputStream (file-read vector present)" >&2
  exit 1
fi
# Security invariants of the BLOB deserialization fix (SAC-31683):
#   3. the readObject() / ObjectInputStream sink must be gone from the source.
if grep -Eq "new ObjectInputStream|\.readObject\(" "${PATCHED_RESULTSET}"; then
  echo "ERROR: ResultSetImpl.java still contains an ObjectInputStream/readObject sink (RCE vector present)" >&2
  exit 1
fi
#   4. ...and the explicit refusal sentinel must be present.
grep -q "Refusing to deserialize object stream from BLOB" "${PATCHED_RESULTSET}" \
  || { echo "ERROR: ResultSetImpl.java is missing the deserialization refusal sentinel" >&2; exit 1; }

# --- 1. Download upstream base jar + pom ------------------------------------
BASE_JAR="${WORK}/base.jar"
BASE_POM="${WORK}/base.pom"
echo ">> Downloading upstream base artifacts from Maven Central"
curl -fsSL "${CENTRAL}/mysql-connector-j-${BASE_VERSION}.jar" -o "${BASE_JAR}"
curl -fsSL "${CENTRAL}/mysql-connector-j-${BASE_VERSION}.pom" -o "${BASE_POM}"

# --- 2. Compile the patched classes against the base jar --------------------
echo ">> Compiling patched NativeProtocol.java + ResultSetImpl.java"
CLASSES="${WORK}/classes"
mkdir -p "${CLASSES}"
javac --release 8 -encoding UTF-8 -cp "${BASE_JAR}" -d "${CLASSES}" \
  "${PATCHED_JAVA}" "${PATCHED_RESULTSET}"

# --- 3. Assemble the patched jar --------------------------------------------
echo ">> Assembling patched jar"
OUT_JAR="${WORK}/mysql-connector-j-${OUT_VERSION}.jar"
cp "${BASE_JAR}" "${OUT_JAR}"
( cd "${CLASSES}" && jar uf "${OUT_JAR}" com/mysql/cj/protocol/a/NativeProtocol*.class )
( cd "${CLASSES}" && jar uf "${OUT_JAR}" com/mysql/cj/jdbc/result/ResultSetImpl*.class )
( cd "${FORK_ROOT}/src/main/resources" && jar uf "${OUT_JAR}" com/mysql/cj/LocalizedErrorMessages.properties )

# --- 4. Verify the compiled fixes are safe in the assembled jar. grep -q on a
#        pipe under `set -o pipefail` fails via SIGPIPE, so extract to a file. --
#   4a. NativeProtocol must carry no FileInputStream (the file-read vector).
javap -p -c -classpath "${OUT_JAR}" com.mysql.cj.protocol.a.NativeProtocol > "${WORK}/nativeprotocol.txt"
if grep -q "FileInputStream" "${WORK}/nativeprotocol.txt"; then
  echo "ERROR: assembled NativeProtocol still references FileInputStream" >&2
  exit 1
fi
#   4b. ResultSetImpl must carry no ObjectInputStream/readObject (the RCE vector).
javap -p -c -classpath "${OUT_JAR}" com.mysql.cj.jdbc.result.ResultSetImpl > "${WORK}/resultsetimpl.txt"
if grep -Eq "ObjectInputStream|readObject" "${WORK}/resultsetimpl.txt"; then
  echo "ERROR: assembled ResultSetImpl still references ObjectInputStream/readObject (RCE vector present)" >&2
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
