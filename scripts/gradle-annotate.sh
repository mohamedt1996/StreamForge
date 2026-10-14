#!/bin/bash
# Runs a Gradle task and turns Kotlin/AAPT/R8 errors into GitHub annotations.
set -uo pipefail
cd android
./gradlew --no-daemon --stacktrace "$@" > ../gradle.log 2>&1
STATUS=$?
cd ..
grep -E "^e: |error:|ERROR:|What went wrong|Could not resolve|Missing class" gradle.log | sort -u | head -80 > gradle-errors.txt || true
while IFS= read -r line; do
  if [[ "$line" =~ ^e:\ file://(/[^:]+):([0-9]+):([0-9]+)\ (.*)$ ]]; then
    file="${BASH_REMATCH[1]#"$GITHUB_WORKSPACE/"}"
    echo "::error file=${file},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[4]}"
  else
    echo "::error::${line:0:900}"
  fi
done < gradle-errors.txt
if [[ $STATUS -ne 0 ]]; then
  grep -A12 "What went wrong" gradle.log | head -40 | while IFS= read -r l; do echo "::error::${l:0:900}"; done
fi
tail -5 gradle.log
exit $STATUS
