#!/bin/sh
# verify.sh - single verification entry point for the ITU project.
#
# Stages: toolchain check, fixture check, compile + all unit tests, public API
# compatibility check, fixed-seed parse fuzz smoke, jar content audit
# (reproducibility + manifest hygiene) and generated-file drift check.
#
# Exit codes:
#   0   all stages passed
#   2   usage error (not run from the repository root)
#   10  required tool missing from the toolchain
#   11  required test fixture / baseline missing
#   12  workspace drift: the build created or modified files outside target/
#   any other code: the original exit code of the failing stage command
#
# The script runs Maven in offline mode (-o). Run 'mvn -q -DskipTests package'
# once after cloning to populate the local repository cache. See VERIFYING.md.

set -u

EXIT_USAGE=2
EXIT_TOOLCHAIN=10
EXIT_FIXTURE=11
EXIT_DRIFT=12

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT" || exit $EXIT_USAGE

if [ ! -f pom.xml ] || [ ! -d src ]; then
    echo "verify: pom.xml/src not found - run 'sh ./verify.sh' from the repository root" >&2
    exit $EXIT_USAGE
fi

MVN="mvn -o -ntp -B"
TOTAL_STAGES=8
STAGE_NO=0

WORK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/itu-verify.XXXXXX") || exit 1
SUMMARY_FILE="$WORK_TMP/summary.txt"
: > "$SUMMARY_FILE"
LOG_DIR="$WORK_TMP/logs"
mkdir -p "$LOG_DIR"
trap 'rm -rf "$WORK_TMP"' EXIT INT TERM

sha256_stdin() { $SHA256_TOOL | awk '{print $1}'; }
sha256_file() { $SHA256_TOOL "$1" | awk '{print $1}'; }

print_summary()
{
    echo
    echo "================ verify summary ================"
    printf '%-18s %-6s %s\n' "stage" "status" "elapsed"
    printf '%-18s %-6s %s\n' "------------------" "------" "-------"
    while IFS='|' read -r name status elapsed; do
        printf '%-18s %-6s %s\n' "$name" "$status" "$elapsed"
    done < "$SUMMARY_FILE"
}

begin_stage()
{
    STAGE_NO=$((STAGE_NO + 1))
    STAGE_NAME=$1
    STAGE_START=$(date +%s)
    echo
    echo "==> [$STAGE_NO/$TOTAL_STAGES] $STAGE_NAME"
}

end_stage()
{
    elapsed=$(($(date +%s) - STAGE_START))
    printf '%s|%s|%ss\n' "$STAGE_NAME" "OK" "$elapsed" >> "$SUMMARY_FILE"
    echo "    [OK] $STAGE_NAME (${elapsed}s)"
}

fail_stage() # <exit-code> <message>
{
    elapsed=$(($(date +%s) - STAGE_START))
    printf '%s|%s|%ss\n' "$STAGE_NAME" "FAIL" "$elapsed" >> "$SUMMARY_FILE"
    echo "    [FAIL] $STAGE_NAME: $2" >&2
    print_summary
    echo "verify: FAILED ($STAGE_NAME), exit code $1" >&2
    exit "$1"
}

run_mvn() # <logfile> <maven-args...>
{
    log=$1
    shift
    $MVN "$@" > "$log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
        tail -n 60 "$log" >&2
        if grep -q "offline mode" "$log"; then
            echo "verify: Maven ran offline (-o) and found missing artifacts." >&2
            echo "verify: run 'mvn -q -DskipTests package' once to populate the cache, then re-run." >&2
        fi
        echo "verify: full log: $log" >&2
    fi
    return $rc
}

jar_entry_hashes() # <jar> -> lines of "<sha256>  <entry>"
{
    unzip -Z1 "$1" | while IFS= read -r entry; do
        h=$(unzip -p "$1" "$entry" | sha256_stdin)
        printf '%s  %s\n' "$h" "$entry"
    done
}

record_run() # <output-dir>
{
    mkdir -p "$1"
    for jar in target/*.jar; do
        b=$(basename "$jar")
        unzip -Z1 "$jar" > "$1/$b.list"
        jar_entry_hashes "$jar" > "$1/$b.hashes"
        sha256_file "$jar" > "$1/$b.sha256"
    done
}

snapshot_workspace() # <prefix>
{
    git status --porcelain > "$1.status"
    git diff HEAD > "$1.diff" 2>/dev/null || : > "$1.diff"
}

audit_manifest() # <jar>
{
    manifest="$WORK_TMP/manifest.txt"
    unzip -p "$1" META-INF/MANIFEST.MF > "$manifest" 2>/dev/null || return 0
    if grep -E '^(Bnd-LastModified|Build-Time|Built-Date|Build-OS|Build-Host|Build-User|Scm-Revision):' "$manifest" >/dev/null; then
        echo "verify: $1 manifest contains a timestamp/host header:" >&2
        grep -E '^(Bnd-LastModified|Build-Time|Built-Date|Build-OS|Build-Host|Build-User|Scm-Revision):' "$manifest" >&2
        return 1
    fi
    if grep -qF "$ROOT" "$manifest"; then
        echo "verify: $1 manifest leaks the build machine path '$ROOT'" >&2
        return 1
    fi
    if [ -n "${HOME:-}" ] && grep -qF "$HOME" "$manifest"; then
        echo "verify: $1 manifest leaks the build machine home path '$HOME'" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- stage 1: toolchain
begin_stage "toolchain"
SHA256_TOOL=""
for candidate in "shasum -a 256" "sha256sum"; do
    if command -v ${candidate%% *} >/dev/null 2>&1; then
        SHA256_TOOL=$candidate
        break
    fi
done
missing=""
for tool in java javap mvn git unzip awk find diff sort; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -z "$SHA256_TOOL" ] && missing="$missing shasum|sha256sum"
if [ -n "$missing" ]; then
    echo "verify: missing required tool(s):$missing" >&2
    fail_stage $EXIT_TOOLCHAIN "toolchain incomplete:$missing"
fi
echo "    java:  $(java -version 2>&1 | head -n 1)"
echo "    maven: $(mvn -version 2>/dev/null | head -n 1)"
echo "    git:   $(git --version 2>/dev/null)"
echo "    sha256: $SHA256_TOOL"
end_stage

# ---------------------------------------------------------------- stage 2: fixtures
begin_stage "fixtures"
missing=""
for fixture in \
    pom.xml \
    src/test/resources/test-data.json \
    src/verify/public-api.txt \
    src/test/java/com/ethlo/time/DeterministicParseSmokeTest.java \
    src/test/java/com/ethlo/time/fuzzer
do
    [ -e "$fixture" ] || missing="$missing $fixture"
done
if [ -n "$missing" ]; then
    echo "verify: missing required fixture(s):$missing" >&2
    fail_stage $EXIT_FIXTURE "fixtures missing:$missing"
fi
echo "    all fixtures present (test-data.json, public-api.txt, smoke + fuzz tests)"
end_stage

# ---------------------------------------------------------------- stage 3: build + unit tests
begin_stage "build+test"
snapshot_workspace "$WORK_TMP/git-before"
# 'rm -rf target' instead of 'mvn clean': the clean plugin is not resolved by the
# 'mvn -DskipTests package' preparation step, so it would be unavailable offline.
rm -rf target
if run_mvn "$LOG_DIR/build.log" package; then
    :
else
    rc=$?
    fail_stage $rc "maven clean package failed (compile or unit tests)"
fi
grep -E "Running com\.|Tests run:.*-- in|Tests run: [0-9]+, Failures" "$LOG_DIR/build.log" | sed 's/^\[INFO\] /    /' | tail -n 8
end_stage

# ---------------------------------------------------------------- stage 4: public API compatibility
begin_stage "api-compat"
ACTUAL="$WORK_TMP/public-api.actual.txt"
( cd target/classes && find com/ethlo/time -name '*.class' ! -name '*$*' ! -path '*internal*' \
    | sed -e 's|/|.|g' -e 's|\.class$||' | sort ) > "$WORK_TMP/api-classes.txt"
: > "$ACTUAL"
while IFS= read -r class_name; do
    javap -public -cp target/classes "$class_name" >> "$ACTUAL.raw" 2>/dev/null || {
        echo "verify: javap failed for $class_name" >&2
        fail_stage 1 "javap failed for $class_name"
    }
done < "$WORK_TMP/api-classes.txt"
grep -v '^Compiled from' "$ACTUAL.raw" > "$ACTUAL"
rm -f "$ACTUAL.raw"
if ! diff -u src/verify/public-api.txt "$ACTUAL" > "$WORK_TMP/public-api.diff" 2>&1; then
    cat "$WORK_TMP/public-api.diff" >&2
    fail_stage 1 "public API changed vs src/verify/public-api.txt (diff shown above)"
fi
echo "    public API matches src/verify/public-api.txt ($(wc -l < "$ACTUAL" | tr -d ' ') signature lines)"
end_stage

# ---------------------------------------------------------------- stage 5: fixed-seed parse smoke
begin_stage "parse-smoke"
if run_mvn "$LOG_DIR/parse-smoke.log" surefire:test -Dtest=DeterministicParseSmokeTest; then
    :
else
    rc=$?
    if [ -f target/verify/smoke/minimal-failing-inputs.txt ]; then
        echo "verify: minimal failing inputs saved to target/verify/smoke/minimal-failing-inputs.txt:" >&2
        cat target/verify/smoke/minimal-failing-inputs.txt >&2
    fi
    fail_stage $rc "deterministic parse smoke failed"
fi
grep -E "Running com\.|Tests run" "$LOG_DIR/parse-smoke.log" | sed 's/^\[INFO\] /    /'
end_stage

# ---------------------------------------------------------------- stage 6: jar content audit
begin_stage "jar-audit"
record_run "$WORK_TMP/run1"
for jar in target/*.jar; do
    if ! audit_manifest "$jar"; then
        fail_stage 1 "manifest audit failed for $jar"
    fi
done
echo "    manifests clean (no build-machine paths, no build timestamps)"
rm -rf target
if run_mvn "$WORK_TMP/rebuild.log" -q -DskipTests package; then
    :
else
    rc=$?
    fail_stage $rc "reproducibility rebuild failed"
fi
record_run "$WORK_TMP/run2"
audit_ok=1
for list in "$WORK_TMP"/run1/*.list; do
    b=$(basename "$list" .list)
    if [ ! -f "$WORK_TMP/run2/$b.list" ]; then
        echo "verify: artifact $b missing after rebuild" >&2
        audit_ok=0
        continue
    fi
    if ! diff -q "$WORK_TMP/run1/$b.list" "$WORK_TMP/run2/$b.list" >/dev/null; then
        echo "verify: entry list of $b differs between identical-commit builds:" >&2
        diff "$WORK_TMP/run1/$b.list" "$WORK_TMP/run2/$b.list" | head -n 20 >&2
        audit_ok=0
    fi
    if ! diff -q "$WORK_TMP/run1/$b.hashes" "$WORK_TMP/run2/$b.hashes" >/dev/null; then
        echo "verify: per-entry hashes of $b differ between identical-commit builds:" >&2
        diff "$WORK_TMP/run1/$b.hashes" "$WORK_TMP/run2/$b.hashes" | head -n 20 >&2
        audit_ok=0
    fi
done
[ $audit_ok -eq 1 ] || fail_stage 1 "jar content audit failed (non-reproducible build)"
echo "    entry lists and per-entry SHA-256 identical across two builds"
end_stage

# ---------------------------------------------------------------- stage 7: workspace drift
begin_stage "drift-check"
snapshot_workspace "$WORK_TMP/git-after"
if ! cmp -s "$WORK_TMP/git-before.status" "$WORK_TMP/git-after.status" || ! cmp -s "$WORK_TMP/git-before.diff" "$WORK_TMP/git-after.diff"; then
    echo "verify: the build generated or modified files outside target/:" >&2
    diff "$WORK_TMP/git-before.status" "$WORK_TMP/git-after.status" >&2
    diff "$WORK_TMP/git-before.diff" "$WORK_TMP/git-after.diff" | head -n 40 >&2
    fail_stage $EXIT_DRIFT "workspace drift detected"
fi
echo "    no generated-file drift outside target/"
end_stage

# ---------------------------------------------------------------- stage 8: final hashes
begin_stage "artifact-hashes"
mkdir -p target/verify/logs target/verify/audit
cp "$LOG_DIR"/*.log target/verify/logs/ 2>/dev/null || true
cp "$WORK_TMP"/run2/*.hashes target/verify/audit/ 2>/dev/null || true
cp "$WORK_TMP/public-api.actual.txt" target/verify/ 2>/dev/null || true
combined="$WORK_TMP/combined.txt"
: > "$combined"
echo "    artifacts (SHA-256):"
for jar in target/*.jar; do
    h=$(sha256_file "$jar")
    printf '    %s  %s\n' "$h" "$jar"
    cat "$WORK_TMP/run2/$(basename "$jar").hashes" >> "$combined"
done
FINAL_HASH=$(sha256_stdin < "$combined")
echo "    final hash (all jar entries, SHA-256): $FINAL_HASH"
echo "$FINAL_HASH" > target/verify/final-hash.txt
end_stage

print_summary
echo
echo "final hash: $FINAL_HASH"
echo "VERIFY OK"
exit 0
