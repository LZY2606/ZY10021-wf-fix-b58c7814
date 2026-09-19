# Verifying `itu`

`verify.sh` is the **single** verification entry point for this repository. It runs from the
repository root, takes no arguments, needs no external services or manually exported environment
variables, and after the one-time dependency download it can be re-run fully offline:

```sh
mvn -q -DskipTests package      # one-time preparation, not part of the verification itself
sh ./verify.sh                  # the only command CI executes
```

A clean run performs a locked-toolchain check, compiles, runs the whole unit-test suite, checks
public API compatibility, executes a fixed-seed parser smoke test, and audits the produced jars.
It prints a per-stage summary on success and exits with a distinct code for each failure class.

## Stages

| # | Stage | What it does |
|---|-------|--------------|
| 1 | `toolchain-lock` | Requires Maven `3.9.16` and a full JDK `26` (the JDK actually used by the Maven runtime), plus `git`, `jar`, `javac`, `javap`, `sha256sum`/`shasum`, etc. Also asserts `pom.xml` pins `project.build.outputTimestamp` to the value locked in the script. |
| 2 | `fixtures-present` | Asserts the committed inputs exist locally and are non-empty: `src/test/resources/test-data.json` (67 cases), the smoke harness and the two baselines. Nothing here is ever downloaded. |
| 3 | `dependency-cache` | On the first run only, performs **one online** `mvn clean test` so every plugin/dependency is in the local Maven repository, then writes `.verify-cache/deps-ready`. From that point on - including the rest of that first run and every future run - all Maven invocations use `--offline`. |
| 4 | `compile` | Offline `mvn clean test-compile`. |
| 5 | `unit-tests` | Offline `mvn test`; parses the Surefire reports and fails if the reported test count is zero. |
| 6 | `api-compat` | Dumps public signatures (`javap -public`) of the exported packages (`com.ethlo.time`, `com.ethlo.time.token`) and diffs them against `verify/public-api.txt`; also diffs the Maven coordinates (`groupId`/`artifactId`/`version`/`packaging`/`finalName`) against `verify/expected-metadata.txt`. |
| 7 | `parser-fuzz-smoke` | Compiles and runs `verify/VerifyFuzzSmoke.java` against `target/classes`, twice. A fixed seed (`0x5EED1741`) makes the 564 generated inputs deterministic; the two runs must produce identical output. Buckets: `offset`, `duration-token`, `leap-day`, `error-position`, `crash-canary`. A disagreement is delta-debugged to a minimal input. |
| 8 | `jar-audit` | Runs **two independent** `mvn clean package` builds. For the main, `-sources`, and `-javadoc` jars it compares the entry listing, every entry's uncompressed sha-256, and the full-jar sha-256 between the two builds. Manifests must contain no build-machine path, no `Built-By`, and no `Bnd-LastModified`. Required entries (`com/ethlo/time/ITU.class`, `META-INF/versions/9/module-info.class`, `com/ethlo/time/ITU.java`, `index.html`) must be present. |
| 9 | `workspace-drift` | Compares `git status --porcelain` before and after the build; any tracked change or untracked file introduced by the build is a failure. |

The smoke test is deliberately **small** (564 inputs) rather than a long fuzz campaign: it targets
offset tokens, duration tokens (`P/T/D/H/M/S/W` and fractions), February-29/leap-second validation,
and parser error positions, while seeded random garbage only guards against unexpected exception
types.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All stages passed. |
| `10` | Toolchain missing or version mismatch (JDK/Maven), or `pom.xml` does not pin the reproducible timestamp. |
| `11` | A required test fixture or committed verify input is missing/empty. |
| `12` | Workspace drift: the build modified a tracked file or created an untracked file. |
| `13` | Public API signatures or Maven coordinates differ from the committed baselines. |
| `14` | Parser smoke test found a parser disagreement; minimal failing inputs are saved. |
| `15` | Jar audit failed: entry listing, per-entry hash, full-jar hash, or manifest differs/leaks. |
| other | The **raw exit code** of the failing underlying command (e.g. `mvn`, `javac`, `java`). The script does not remap or swallow it. |

When a command fails, the script prints its failing stage, the exact command, its exit code, and
the last 80 log lines; it never retries online on its own and never downloads test inputs.

## Cache boundaries

- `.verify-cache/deps-ready` is the online/offline boundary. Its presence forces `--offline` for
  every Maven call. Delete it to intentionally perform the one-time online warm-up again.
- The dependency warm-up uses Maven only. Test **inputs** (fixtures, harness, baselines) live in
  the repository and a missing one is an exit-`11` failure, never a network fetch.
- With the marker present and the local Maven repository intact, `sh ./verify.sh` works without
  any network access. A missing plugin/dependency in offline mode fails with Maven's own exit
  code; remove the marker to re-warm deliberately.
- Reproducible artifacts rely on `project.build.outputTimestamp=2020-01-01T00:00:00Z` (pinned in
  `pom.xml`, passed on every build by `verify.sh`). This removes zip entry timestamps and the
  volatile `Bnd-LastModified` manifest header.

## Artifact and output locations

| Path | Contents |
|------|----------|
| `target/itu-1.15.0-SNAPSHOT.jar` | Main OSGi bundle (also a multi-release jar with `META-INF/versions/9/module-info.class`). |
| `target/itu-1.15.0-SNAPSHOT-sources.jar` | Source archive, audited together with the main jar. |
| `target/itu-1.15.0-SNAPSHOT-javadoc.jar` | Javadoc archive, audited together with the main jar. |
| `.verify/logs/` | Full per-stage command logs (`03-…` … `09-…`). |
| `.verify/findings/` | Minimal failing inputs from the smoke test (empty on success). |
| `.verify/build-a`, `.verify/build-b` | Jars from the two audited clean builds. |
| `.verify/*.diff` | API, metadata, jar-listing and jar-entry hash diffs on failure. |
| `.verify/jar-hashes.txt` | Full-jar sha-256 values shown in the summary. |
| `verify/` | Committed inputs: `VerifyFuzzSmoke.java`, `public-api.txt`, `expected-metadata.txt`. |

`.verify/` and `.verify-cache/` are git-ignored. The ProGuard `-small` jar is only produced on
JDK `[9,22)`; the locked toolchain is JDK 26, so exactly the three jars above are audited.

## Updating baselines intentionally

Public API or coordinate changes are supposed to change the baselines. After reviewing the diff,
regenerate them with the maintainer helper (this is not used by CI and never invoked by
`verify.sh`):

```sh
sh verify/regen-baselines.sh     # rewrites verify/public-api.txt
# edit verify/expected-metadata.txt by hand for coordinate changes
```

## Demo output

Per-stage summary and final hashes from a successful run (same commit run twice yields the same
hashes):

```text
======================== verify summary ========================
  toolchain-lock      OK  maven=3.9.16;java=26
  fixtures-present    OK  test-data.json;harness;baselines
  dependency-cache    OK  offline (marker present)
  compile             OK  clean test-compile
  unit-tests          OK  tests=332
  api-compat          OK  com.ethlo.time:itu:1.15.0-SNAPSHOT
  parser-fuzz-smoke   OK  total-inputs=564 total-findings=0
  jar-audit           OK  3 jars;two builds;identical entries+hashes
  workspace-drift     OK  no tracked or untracked drift
----------------------------------------------------------------
artifacts (two clean builds, outputTimestamp=2020-01-01T00:00:00Z):
  sha256:2ec04390ebab5b16466fbbd18101b89f0862a0d2145b9ee52bb73fe0f2a5c58d  itu-1.15.0-SNAPSHOT.jar
  sha256:ab7075711d8d533807b4fa900a0e175c107035e2d9e67a7394519d12d7d61f3e  itu-1.15.0-SNAPSHOT-sources.jar
  sha256:07e6aaa2ce1e102e505e8021a7ca6bf12e505ba1d3b599cab209e3fb50865a62  itu-1.15.0-SNAPSHOT-javadoc.jar
----------------------------------------------------------------
logs:     .verify/logs/
findings: .verify/findings/ (empty on success)
cache:    .verify-cache/deps-ready marks the online->offline boundary
offline:  next 'sh ./verify.sh' run uses Maven --offline for every build
================================================================
```

A parser disagreement ends the run with exit code `14` and preserves a minimized input, e.g.:

```text
parser-fuzz-smoke: MINIMAL FAILING INPUT [offset] 2024-01-01T12:00:00+08
parser-fuzz-smoke: minimized findings written to .verify/findings
```
