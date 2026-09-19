# Verifying the build

`verify.sh` is the single verification entry point for this repository. It checks the
parser behaviour, the public API and the Maven publication metadata in one run, so a
green local run means the same thing as a green CI run. CI (`.github/workflows/build.yml`)
calls this script and nothing else; there are no CI-only flags.

## Quick start

    # One-time preparation after cloning (downloads dependencies, not part of verification):
    mvn -q -DskipTests package

    # Verification, from the repository root:
    sh ./verify.sh

`verify.sh` runs Maven in offline mode (`-o`) and never touches the network itself. If
the local repository cache is incomplete it stops and tells you to run the preparation
command above instead of silently downloading anything. After the preparation step has
completed once, `sh ./verify.sh` can be re-run offline as many times as needed.

## Stages

| # | Stage | What it does |
|---|-------|--------------|
| 1 | `toolchain` | Checks that `java`, `javap`, `mvn`, `git`, `unzip` and a SHA-256 tool (`shasum` or `sha256sum`) are present, and prints their versions. |
| 2 | `fixtures` | Checks that required inputs exist: `src/test/resources/test-data.json`, the API baseline `src/verify/public-api.txt`, the smoke test and the fuzz test sources. |
| 3 | `build+test` | Removes `target/` and runs `mvn -o package`: compiles and executes the full unit test suite (including the Jazzer-based fuzz regression tests). |
| 4 | `api-compat` | Dumps the public signatures of the exported packages (`com.ethlo.time`, `com.ethlo.time.token`) with `javap -public` and diffs them against the checked-in baseline `src/verify/public-api.txt`. Any public API change fails the build with a diff. |
| 5 | `parse-smoke` | Runs `DeterministicParseSmokeTest`: a fixed-seed (deterministic) parse fuzz smoke over `parseDateTime`, `parseLenient` and `parseDuration`, plus targeted cases for timezone offsets, duration tokens, leap days and error positions. On failure the input is shrunk and the minimal failing input is saved (see below). |
| 6 | `jar-audit` | Audits `target/*.jar`: the manifest must not contain build-machine paths or build timestamps (`Bnd-LastModified`, `Build-Time`, ...). Then rebuilds from the same commit and requires identical entry lists and identical per-entry SHA-256 hashes for the main, sources and javadoc jars. |
| 7 | `drift-check` | Compares `git status` / `git diff HEAD` before and after the build. Any file the build creates or modifies outside `target/` (e.g. license-header rewrites) is reported as drift. |
| 8 | `artifact-hashes` | Prints the SHA-256 of every jar and a combined final hash over all jar entries, and writes it to `target/verify/final-hash.txt`. |

Reproducibility is anchored by `project.build.outputTimestamp` in `pom.xml` (fixed zip
entry timestamps, no `Bnd-LastModified`) and `<notimestamp>true</notimestamp>` for
Javadoc, so two runs on the same commit produce the same final hash.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | All stages passed. |
| `2`  | Usage error (not run from the repository root). |
| `10` | Toolchain incomplete - a required tool is missing. |
| `11` | A required test fixture or baseline is missing. |
| `12` | Workspace drift - the build generated or modified files outside `target/`. |
| other | The original exit code of the failing stage command (e.g. `1` from Maven, Surefire or `diff`). The script never swallows or rewrites a failure code. |

## Cache boundaries

* All Maven artifacts live in the standard local repository (`~/.m2/repository`). The
  one-time preparation command `mvn -q -DskipTests package` populates everything the
  offline run needs; the surefire JUnit provider and the JUnit Jupiter engine are
  declared explicitly in `pom.xml` so that they are cached by that command as well.
* `verify.sh` itself always runs Maven with `-o` (offline). It does not fall back to
  the network to fill in missing input.
* `target/` is the only directory the build writes to and is fully removed and
  recreated during the run. Nothing is cached between runs besides the Maven
  repository.

## Artifacts

| Path | Content |
|------|---------|
| `target/itu-*-SNAPSHOT.jar` | Main, sources and javadoc jars (rebuilt twice and compared). |
| `target/verify/logs/` | Maven logs of the build and the parse-smoke stage. |
| `target/verify/audit/` | Per-entry SHA-256 listings of every jar from the audit run. |
| `target/verify/public-api.actual.txt` | The API signature dump compared against the baseline. |
| `target/verify/final-hash.txt` | The combined SHA-256 over all jar entries. |
| `target/verify/smoke/minimal-failing-inputs.txt` | Only created on smoke-test failure: seed, iteration and the shrunken minimal failing input. |

## Example output

    $ sh ./verify.sh

    ==> [1/8] toolchain
        java:  openjdk version "24.0.1" 2025-04-15
        maven: Apache Maven 3.9.16 (2bdd9fddda4b155ebf8000e807eb73fd829a51d5)
        git:   git version 2.50.1 (Apple Git-155)
        sha256: shasum -a 256
        [OK] toolchain (0s)

    ==> [2/8] fixtures
        all fixtures present (test-data.json, public-api.txt, smoke + fuzz tests)
        [OK] fixtures (0s)

    ==> [3/8] build+test
        Running com.ethlo.time.DeterministicParseSmokeTest
        Tests run: 5, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.011 s -- in com.ethlo.time.DeterministicParseSmokeTest
        Tests run: 437, Failures: 0, Errors: 0, Skipped: 0
        [OK] build+test (6s)

    ==> [4/8] api-compat
        public API matches src/verify/public-api.txt (204 signature lines)
        [OK] api-compat (2s)

    ==> [5/8] parse-smoke
        Running com.ethlo.time.DeterministicParseSmokeTest
        Tests run: 5, Failures: 0, Errors: 0, Skipped: 0
        [OK] parse-smoke (2s)

    ==> [6/8] jar-audit
        manifests clean (no build-machine paths, no build timestamps)
        entry lists and per-entry SHA-256 identical across two builds
        [OK] jar-audit (9s)

    ==> [7/8] drift-check
        no generated-file drift outside target/
        [OK] drift-check (0s)

    ==> [8/8] artifact-hashes
        artifacts (SHA-256):
    1823a77a72f0fec4e4fd31a8911a139092c988f172e1edc6300c45bbf887c081  target/itu-1.15.0-SNAPSHOT-javadoc.jar
    ca5a7118eec4034bb62c669685e87da7ab9b01ff9d072a20208be35711edea89  target/itu-1.15.0-SNAPSHOT-sources.jar
    59b9bc97e1033dfa8cc34eb8a94da511aa99fb93496a4b5cd1287477f925a71b  target/itu-1.15.0-SNAPSHOT.jar
    final hash (all jar entries, SHA-256): 6556b91be848d336b1bda13c9bd60666a8da54485a5c3cd847a9ab9709330fa0
        [OK] artifact-hashes (0s)

    ================ verify summary ================
    stage              status elapsed
    ------------------ ------ -------
    toolchain          OK     0s
    fixtures           OK     0s
    build+test         OK     6s
    api-compat         OK     2s
    parse-smoke        OK     2s
    jar-audit          OK     9s
    drift-check        OK     0s
    artifact-hashes    OK     0s

    final hash: 6556b91be848d336b1bda13c9bd60666a8da54485a5c3cd847a9ab9709330fa0
    VERIFY OK
