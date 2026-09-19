#!/bin/sh
# Regenerates the committed baselines consumed by verify.sh's api-compat stage.
# This is a maintainer helper, intentionally separate from verify.sh: CI only ever calls
# `sh ./verify.sh`, and verify.sh never regenerates baselines itself.
#
# Usage: sh verify/regen-baselines.sh   (after an intentional public API / coordinate change)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

echo "compiling classes ..."
mvn -B -ntp -q -DskipTests compile

out=verify/public-api.txt
: >"$out"
classes=$(cd target/classes \
    && { find com/ethlo/time -maxdepth 1 -name '*.class' ! -name '*$*' -type f; \
         find com/ethlo/time/token -name '*.class' ! -name '*$*' -type f; } \
    | sed 's#/#.#g; s#\.class$##' | sort)
for cls in $classes; do
    echo "===== $cls" >>"$out"
    javap -public -classpath target/classes "$cls" >>"$out"
done
echo "updated $out ($(wc -l <"$out") lines)"
