#!/bin/sh
#
# verify.sh - single verification entry point for the itu project.
#
# Runs, from a clean checkout and after dependencies have been downloaded once, a fully
# offline-able chain of gates:
#
#   1. toolchain-lock      pinned JDK/Maven plus required shell tools
#   2. fixtures-present    committed test data and verify inputs exist locally
#   3. dependency-cache    one online warm-up, then every Maven call runs with -o
#   4. compile             clean test-compile
#   5. unit-tests          all JUnit tests via surefire
#   6. api-compat          public API signature and Maven coordinate baselines
#   7. parser-fuzz-smoke   fixed-seed parser smoke test (offsets/durations/leap days/positions)
#   8. jar-audit           two clean builds: identical jar entries, hashes and clean manifests
#   9. workspace-drift     no tracked file was modified/created by the build
#
# Exit codes:
#   0   all stages passed
#   10  toolchain missing or version mismatch
#   11  required test fixture / verify input missing
#   12  workspace drift: build modified or created tracked files
#   13  public API or Maven metadata does not match the committed baseline
#   14  parser fuzz smoke found a parser mismatch (minimal inputs saved)
#   15  jar audit failed (content/hash/manifest mismatch)
#   any other non-zero value: the raw exit code of the failing underlying command
#
# This script takes no arguments and never consults network to obtain test inputs.
# See VERIFYING.md for the full description, cache boundaries and artifact locations.

set -u

# ----------------------------------------------------------------------------
# Locked toolchain and reproducible-build constants
# ----------------------------------------------------------------------------
REQUIRED_JAVA_MAJOR=26
REQUIRED_MAVEN_VERSION=3.9.16
# Must equal the <project.build.outputTimestamp> pinned in pom.xml.
OUTPUT_TIMESTAMP=2020-01-01T00:00:00Z

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT" || {
    echo "verify: cannot enter repository root: $ROOT" >&2
    exit 10
}

VERIFY_DIR="$ROOT/verify"
OUT_DIR="$ROOT/.verify"
LOG_DIR="$OUT_DIR/logs"
FINDINGS_DIR="$OUT_DIR/findings"
HARNESS_CLASSES="$OUT_DIR/harness-classes"
BUILD_A="$OUT_DIR/build-a"
BUILD_B="$OUT_DIR/build-b"
CACHE_DIR="$ROOT/.verify-cache"
DEPS_MARKER="$CACHE_DIR/deps-ready"
STATUS_BEFORE="$OUT_DIR/status-before.txt"
STATUS_AFTER="$OUT_DIR/status-after.txt"
JAR_HASHES="$OUT_DIR/jar-hashes.txt"
SUMMARY="$OUT_DIR/stages.tsv"
BASELINE_API="$VERIFY_DIR/public-api.txt"
BASELINE_META="$VERIFY_DIR/expected-metadata.txt"
HARNESS_SRC="$VERIFY_DIR/VerifyFuzzSmoke.java"
FIXTURE_TESTDATA="$ROOT/src/test/resources/test-data.json"
EXPECTED_JARS="itu-1.15.0-SNAPSHOT.jar itu-1.15.0-SNAPSHOT-sources.jar itu-1.15.0-SNAPSHOT-javadoc.jar"

fail_toolchain() { echo "verify: [toolchain-lock] $1" >&2; exit 10; }
fail_fixture() { echo "verify: [fixtures-present] $1" >&2; exit 11; }
fail_drift() { echo "verify: [workspace-drift] $1" >&2; exit 12; }
fail_api() { echo "verify: [api-compat] $1" >&2; exit 13; }
fail_fuzz() { echo "verify: [parser-fuzz-smoke] $1" >&2; exit 14; }
fail_jar() { echo "verify: [jar-audit] $1" >&2; exit 15; }

stage_header() {
    echo ""
    echo "==> [$1/9] $2"
}

record_ok() {
    printf '%s\tOK\t%s\n' "$1" "$2" >>"$SUMMARY"
}

# run_cmd <stage> <logfile> <command...>
# Preserves the raw exit code of the underlying command on failure.
run_cmd() {
    _stage=$1
    _log=$2
    shift 2
    echo "verify: running: $*"
    echo "$ $*" >"$_log"
    "$@" >>"$_log" 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        echo "verify: [$_stage] command failed with exit code $_rc: $*" >&2
        echo "verify: last 80 log lines from $_log:" >&2
        tail -n 80 "$_log" >&2
        exit "$_rc"
    fi
}

# safe_clean <dir>: remove a directory only when it is the dedicated verify work area
# (.verify/...). Refuses anything else instead of performing an unrestricted recursive delete.
safe_clean() {
    _target=$1
    case "$_target" in
        "$OUT_DIR"/*)
            if [ -d "$_target" ]; then
                # POSIX find deletion, scoped to the verified verify-work directory.
                find "$_target" -depth -type f -exec rm -f {} +
                find "$_target" -depth -type d -exec rmdir {} +
            fi
            ;;
        *)
            echo "verify: refusing to clean outside verify work area: $_target" >&2
            exit 10
            ;;
    esac
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail_toolchain "required command not found on PATH: $1"
}

# ----------------------------------------------------------------------------
# Stage 1: toolchain lock
# ----------------------------------------------------------------------------
stage_header 1 toolchain-lock
mkdir -p "$LOG_DIR" "$FINDINGS_DIR" "$HARNESS_CLASSES" "$BUILD_A" "$BUILD_B" "$CACHE_DIR"
: >"$SUMMARY"

for cmd in mvn git jar javac javap java find sort diff sed grep awk tail wc cut dirname; do
    need_command "$cmd"
done

if command -v sha256sum >/dev/null 2>&1; then
    SHA256=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    SHA256="shasum -a 256"
else
    fail_toolchain "neither sha256sum nor shasum found"
fi

MV_VERSION_OUT=$(mvn -version 2>&1) || fail_toolchain "cannot execute 'mvn -version'"
MV_VERSION=$(printf '%s\n' "$MV_VERSION_OUT" | sed -n 's/^Apache Maven \([0-9][0-9.]*\).*$/\1/p')
[ "$MV_VERSION" = "$REQUIRED_MAVEN_VERSION" ] \
    || fail_toolchain "Maven $REQUIRED_MAVEN_VERSION required, found: '${MV_VERSION:-unknown}'"

MV_JAVA_HOME=$(printf '%s\n' "$MV_VERSION_OUT" | sed -n 's/.*runtime: \(.*\)$/\1/p')
MV_JAVA_VERSION=$(printf '%s\n' "$MV_VERSION_OUT" | sed -n 's/.*Java version: \([0-9][0-9.]*\).*$/\1/p')
if [ -n "$MV_JAVA_HOME" ] && [ -x "$MV_JAVA_HOME/bin/java" ]; then
    JAVA_BIN="$MV_JAVA_HOME/bin/java"
    JAVAC_BIN="$MV_JAVA_HOME/bin/javac"
    JAVAP_BIN="$MV_JAVA_HOME/bin/javap"
    JAR_BIN="$MV_JAVA_HOME/bin/jar"
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    JAVA_BIN="$JAVA_HOME/bin/java"
    JAVAC_BIN="$JAVA_HOME/bin/javac"
    JAVAP_BIN="$JAVA_HOME/bin/javap"
    JAR_BIN="$JAVA_HOME/bin/jar"
    MV_JAVA_VERSION=$($JAVA_BIN -version 2>&1 | sed -n 's/.*version "\([0-9][0-9.]*\).*$/\1/p' | head -n 1)
else
    fail_toolchain "cannot locate the JDK used by Maven (set JAVA_HOME or install a full JDK)"
fi

MV_JAVA_MAJOR=$(printf '%s' "$MV_JAVA_VERSION" | sed 's/\..*$//')
[ "$MV_JAVA_MAJOR" = "$REQUIRED_JAVA_MAJOR" ] \
    || fail_toolchain "JDK $REQUIRED_JAVA_MAJOR required for the Maven runtime, found Java $MV_JAVA_VERSION at $MV_JAVA_HOME"
[ -x "$JAVAC_BIN" ] || fail_toolchain "javac missing in $MV_JAVA_HOME - a full JDK is required"

# The pinned timestamp must match the pom property; otherwise manifests would silently drift.
grep -q "<project.build.outputTimestamp>$OUTPUT_TIMESTAMP</project.build.outputTimestamp>" "$ROOT/pom.xml" \
    || fail_toolchain "pom.xml does not pin project.build.outputTimestamp to $OUTPUT_TIMESTAMP"

echo "verify: maven=$MV_VERSION java=$MV_JAVA_VERSION ($MV_JAVA_HOME) sha256=$SHA256"
record_ok toolchain-lock "maven=$MV_VERSION;java=$MV_JAVA_MAJOR"

# ----------------------------------------------------------------------------
# Stage 2: fixtures and committed verify inputs must be present locally
# ----------------------------------------------------------------------------
stage_header 2 fixtures-present
for required in \
    "$FIXTURE_TESTDATA" \
    "$HARNESS_SRC" \
    "$BASELINE_API" \
    "$BASELINE_META" \
    "$ROOT/pom.xml"; do
    [ -f "$required" ] || fail_fixture "missing required file (never downloaded by this script): $required"
done
[ -s "$FIXTURE_TESTDATA" ] || fail_fixture "test fixture is empty: $FIXTURE_TESTDATA"
grep -q '"input"' "$FIXTURE_TESTDATA" || fail_fixture "test fixture contains no input cases: $FIXTURE_TESTDATA"
echo "verify: test-data cases=$(grep -c '"input"' "$FIXTURE_TESTDATA")"
record_ok fixtures-present "test-data.json;harness;baselines"

# Snapshot the work tree before any build touches it (used by stage 9).
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail_toolchain "repository root is not a git work tree"
git status --porcelain >"$STATUS_BEFORE"

# Maven invocation wrapper: after the one-time warm-up every call is forced offline.
mvn_run() {
    _stage=$1
    _log=$2
    shift 2
    if [ -f "$DEPS_MARKER" ]; then
        run_cmd "$_stage" "$_log" mvn -B -ntp -o \
            -Dproject.build.outputTimestamp="$OUTPUT_TIMESTAMP" "$@"
    else
        run_cmd "$_stage" "$_log" mvn -B -ntp \
            -Dproject.build.outputTimestamp="$OUTPUT_TIMESTAMP" "$@"
    fi
}

# ----------------------------------------------------------------------------
# Stage 3: dependency cache boundary
#
# First run on a machine: executes the full Maven build ONLINE exactly once so every plugin and
# dependency needed by the later stages is in the local repository, then marks the cache ready.
# Every subsequent Maven invocation - including the rest of this very script and every future
# re-run - uses -o (offline). Missing artifacts after the warm-up fail with Maven's raw exit
# code; the script never silently retries online.
# ----------------------------------------------------------------------------
stage_header 3 dependency-cache
if [ -f "$DEPS_MARKER" ]; then
    echo "verify: dependency marker present ($DEPS_MARKER) - all Maven calls use --offline"
    record_ok dependency-cache "offline (marker present)"
else
    echo "verify: no dependency marker yet - one-time ONLINE warm-up (test phase populates all artifacts)"
    mvn_run dependency-cache "$LOG_DIR/03-dependency-cache.log" clean test
    : >"$DEPS_MARKER"
    echo "verify: warm-up complete; future runs are offline-only. marker=$DEPS_MARKER"
    record_ok dependency-cache "online warm-up completed"
fi

# ----------------------------------------------------------------------------
# Stage 4: compile (offline after warm-up)
# ----------------------------------------------------------------------------
stage_header 4 compile
mvn_run compile "$LOG_DIR/04-compile.log" clean test-compile
record_ok compile "clean test-compile"

# ----------------------------------------------------------------------------
# Stage 5: all unit tests
# ----------------------------------------------------------------------------
stage_header 5 unit-tests
mvn_run unit-tests "$LOG_DIR/05-unit-tests.log" test
TEST_TOTAL=$(sed -n 's/.*Tests run: \([0-9]*\), Failures.*/\1/p' "$ROOT/target/surefire-reports"/*.txt 2>/dev/null \
    | awk '{n+=$1} END {print n+0}')
[ "$TEST_TOTAL" -gt 0 ] || { echo "verify: [unit-tests] no surefire results parsed" >&2; exit 1; }
echo "verify: surefire tests-run=$TEST_TOTAL"
record_ok unit-tests "tests=$TEST_TOTAL"

# ----------------------------------------------------------------------------
# Stage 6: public API compatibility + Maven metadata
# ----------------------------------------------------------------------------
stage_header 6 api-compat
API_CURRENT="$OUT_DIR/public-api.current.txt"
: >"$API_CURRENT"
API_CLASSES=$(
    cd "$ROOT/target/classes" || exit 13
    {
        find com/ethlo/time -maxdepth 1 -name '*.class' ! -name '*$*' -type f
        find com/ethlo/time/token -name '*.class' ! -name '*$*' -type f
    } | sed -e 's#/#.#g' -e 's#\.class$##' | sort
)
for cls in $API_CLASSES; do
    echo "===== $cls" >>"$API_CURRENT"
    "$JAVAP_BIN" -public -classpath "$ROOT/target/classes" "$cls" >>"$API_CURRENT" 2>&1 \
        || fail_api "javap failed for $cls"
done
diff -u "$BASELINE_API" "$API_CURRENT" >"$OUT_DIR/public-api.diff" || fail_api \
    "public API changed vs verify/public-api.txt (see .verify/public-api.diff; update deliberately via verify/regen-baselines.sh)"

# Extract current coordinates from pom.xml without invoking a network-bound plugin.
pom_value() { sed -n "s/.*<$1>\(.*\)<\/$1>.*/\1/p" "$ROOT/pom.xml" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n 1; }
CURRENT_GROUP=$(pom_value groupId)
CURRENT_ARTIFACT=$(pom_value artifactId)
CURRENT_PACKAGING=$(pom_value packaging)
CURRENT_VERSION=$(pom_value version)
CURRENT_FINAL="$CURRENT_ARTIFACT-$CURRENT_VERSION"
META_DIFF="$OUT_DIR/metadata.diff"
{
    for pair in \
        "groupId=$CURRENT_GROUP" \
        "artifactId=$CURRENT_ARTIFACT" \
        "packaging=$CURRENT_PACKAGING" \
        "version=$CURRENT_VERSION" \
        "finalName=$CURRENT_FINAL"; do
        echo "$pair"
    done
} | sort >"$OUT_DIR/metadata.current.txt"
grep -v '^#' "$BASELINE_META" | grep '=' | sort >"$OUT_DIR/metadata.expected.txt"
diff -u "$OUT_DIR/metadata.expected.txt" "$OUT_DIR/metadata.current.txt" >"$META_DIFF" \
    || fail_api "Maven coordinates changed vs verify/expected-metadata.txt (see $META_DIFF)"
echo "verify: $CURRENT_GROUP:$CURRENT_ARTIFACT:$CURRENT_VERSION packaging=$CURRENT_PACKAGING"
record_ok api-compat "$CURRENT_GROUP:$CURRENT_ARTIFACT:$CURRENT_VERSION"

# ----------------------------------------------------------------------------
# Stage 7: fixed-seed parser fuzz smoke
# ----------------------------------------------------------------------------
stage_header 7 parser-fuzz-smoke
safe_clean "$FINDINGS_DIR"
safe_clean "$HARNESS_CLASSES"
mkdir -p "$FINDINGS_DIR" "$HARNESS_CLASSES"
run_cmd parser-fuzz-smoke "$LOG_DIR/07-fuzz-compile.log" \
    "$JAVAC_BIN" -encoding UTF-8 -cp "$ROOT/target/classes" -d "$HARNESS_CLASSES" "$HARNESS_SRC"
run_cmd parser-fuzz-smoke "$LOG_DIR/07-fuzz-run-1.log" \
    "$JAVA_BIN" -cp "$ROOT/target/classes:$HARNESS_CLASSES" VerifyFuzzSmoke "$FINDINGS_DIR"
run_cmd parser-fuzz-smoke "$LOG_DIR/07-fuzz-run-2.log" \
    "$JAVA_BIN" -cp "$ROOT/target/classes:$HARNESS_CLASSES" VerifyFuzzSmoke "$OUT_DIR/findings-rerun"
grep '^parser-fuzz-smoke:' "$LOG_DIR/07-fuzz-run-1.log" >"$OUT_DIR/fuzz-output-1.txt"
grep '^parser-fuzz-smoke:' "$LOG_DIR/07-fuzz-run-2.log" >"$OUT_DIR/fuzz-output-2.txt"
diff -u "$OUT_DIR/fuzz-output-1.txt" "$OUT_DIR/fuzz-output-2.txt" >/dev/null \
    || fail_fuzz "two fixed-seed runs produced different output (non-deterministic smoke test)"
if [ -n "$(ls -A "$FINDINGS_DIR" 2>/dev/null)" ]; then
    echo "verify: minimal failing inputs preserved in $FINDINGS_DIR:" >&2
    ls -1 "$FINDINGS_DIR" >&2
    fail_fuzz "parser disagreements found; inspect $FINDINGS_DIR"
fi
FUZZ_SUMMARY=$(grep 'total-inputs=' "$LOG_DIR/07-fuzz-run-1.log")
echo "verify: $FUZZ_SUMMARY"
record_ok parser-fuzz-smoke "$(echo "$FUZZ_SUMMARY" | sed 's/parser-fuzz-smoke: //')"

# ----------------------------------------------------------------------------
# Stage 8: jar audit
#
# Two independent clean package builds. For the main, sources and javadoc jars:
#   - the entry listing is identical between builds,
#   - every entry's uncompressed sha-256 is identical,
#   - the complete jar sha-256 is identical,
#   - the manifest contains no absolute build-machine path and no build timestamp.
# ----------------------------------------------------------------------------
stage_header 8 jar-audit

jar_audit_build() {
    _dest=$1
    _log=$2
    mvn_run jar-audit "$_log" clean package -DskipTests
    mkdir -p "$_dest"
    for j in $EXPECTED_JARS; do
        [ -f "$ROOT/target/$j" ] || fail_jar "expected artifact missing after build: target/$j"
        cp "$ROOT/target/$j" "$_dest/$j"
    done
}

jar_entry_hashes() {
    _jar=$1
    _work=$2
    safe_clean "$_work"
    mkdir -p "$_work"
    (cd "$_work" && "$JAR_BIN" xf "$_jar")
    (cd "$_work" && find . -type f | sed 's#^\./##' | sort | while IFS= read -r f; do
        $SHA256 "$_work/$f" | awk -v name="$f" '{print name" "$1}'
    done)
}

jar_entry_list() {
    "$JAR_BIN" tf "$1" | grep -v '/$' | sort
}

audit_one_jar() {
    _j=$1
    jar_entry_list "$BUILD_A/$_j" >"$OUT_DIR/$_j.list.a"
    jar_entry_list "$BUILD_B/$_j" >"$OUT_DIR/$_j.list.b"
    diff -u "$OUT_DIR/$_j.list.a" "$OUT_DIR/$_j.list.b" >"$OUT_DIR/$_j.list.diff" \
        || fail_jar "entry listing differs between builds for $_j"

    jar_entry_hashes "$BUILD_A/$_j" "$OUT_DIR/x-a" >"$OUT_DIR/$_j.entries.a"
    jar_entry_hashes "$BUILD_B/$_j" "$OUT_DIR/x-b" >"$OUT_DIR/$_j.entries.b"
    diff -u "$OUT_DIR/$_j.entries.a" "$OUT_DIR/$_j.entries.b" >"$OUT_DIR/$_j.entries.diff" \
        || fail_jar "per-entry hash differs between builds for $_j"

    _ha=$($SHA256 "$BUILD_A/$_j" | awk '{print $1}')
    _hb=$($SHA256 "$BUILD_B/$_j" | awk '{print $1}')
    [ "$_ha" = "$_hb" ] || fail_jar "full jar sha-256 differs for $_j"
    printf '%s  %s\n' "$_ha" "$_j" >>"$JAR_HASHES"

    (cd "$OUT_DIR/x-a" && jar_manifest_checks "$_j" "META-INF/MANIFEST.MF")
}

jar_manifest_checks() {
    _j=$1
    _mf=$2
    [ -f "$_mf" ] || fail_jar "manifest missing in $_j: $_mf"
    # No absolute paths of the build machine, no volatile timestamps.
    if grep -Eq "$ROOT|/Users/|/home/|^Bnd-LastModified:|Built-By:" "$_mf"; then
        echo "--- offending manifest ($_j):" >&2
        cat "$_mf" >&2
        fail_jar "manifest of $_j leaks a build-machine path, user or timestamp"
    fi
}

: >"$JAR_HASHES"
jar_audit_build "$BUILD_A" "$LOG_DIR/08-package-a.log"
jar_audit_build "$BUILD_B" "$LOG_DIR/08-package-b.log"
for j in $EXPECTED_JARS; do
    audit_one_jar "$j"
done

# Structural presence checks so that a repackaged-but-hollow jar is caught.
jar_entry_list "$BUILD_A/itu-1.15.0-SNAPSHOT.jar" | grep -qx 'com/ethlo/time/ITU.class' \
    || fail_jar "main jar is missing com/ethlo/time/ITU.class"
jar_entry_list "$BUILD_A/itu-1.15.0-SNAPSHOT.jar" | grep -qx 'META-INF/versions/9/module-info.class' \
    || fail_jar "main jar is missing META-INF/versions/9/module-info.class"
jar_entry_list "$BUILD_A/itu-1.15.0-SNAPSHOT-sources.jar" | grep -qx 'com/ethlo/time/ITU.java' \
    || fail_jar "sources jar is missing com/ethlo/time/ITU.java"
jar_entry_list "$BUILD_A/itu-1.15.0-SNAPSHOT-javadoc.jar" | grep -qx 'index.html' \
    || fail_jar "javadoc jar is missing index.html"
record_ok jar-audit "3 jars;two builds;identical entries+hashes"

# ----------------------------------------------------------------------------
# Stage 9: workspace drift
# ----------------------------------------------------------------------------
stage_header 9 workspace-drift
git status --porcelain >"$STATUS_AFTER"
# Drift = a status entry that was NOT present before the build ran. Every status line present at
# start is filtered out exactly (including pre-existing intended edits), so only files created or
# modified by the build itself are reported. Ignored output dirs (.verify, .verify-cache, target)
# never show up in --porcelain output at all.
ADDED=$(awk 'NR==FNR {seen[$0]=1; next} !($0 in seen)' "$STATUS_BEFORE" "$STATUS_AFTER" || true)
if [ -n "$ADDED" ]; then
    echo "$ADDED" >&2
    fail_drift "the build produced uncommitted workspace changes (listed above)"
fi
record_ok workspace-drift "no tracked or untracked drift"

# Rebuild final artifacts once more so target/*.jar reflects the audited byte content.
mvn_run workspace-drift "$LOG_DIR/09-restore-artifacts.log" clean package -DskipTests

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo ""
echo "======================== verify summary ========================"
awk -F '\t' '{printf "  %-19s %s  %s\n", $1, $2, $3}' "$SUMMARY"
echo "----------------------------------------------------------------"
echo "artifacts (two clean builds, outputTimestamp=$OUTPUT_TIMESTAMP):"
while IFS= read -r line; do echo "  sha256:$line"; done <"$JAR_HASHES"
echo "----------------------------------------------------------------"
echo "logs:     .verify/logs/"
echo "findings: .verify/findings/ (empty on success)"
echo "cache:    .verify-cache/deps-ready marks the online->offline boundary"
if [ -f "$DEPS_MARKER" ]; then
    echo "offline:  next 'sh ./verify.sh' run uses Maven --offline for every build"
else
    echo "offline:  dependency warm-up completed during this run; next run is offline"
fi
echo "================================================================"
exit 0
