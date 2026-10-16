#!/bin/bash
# Runs xcodebuild, turns compiler errors into GitHub annotations, and fails honestly.
# Usage: scripts/xcbuild.sh <scheme> <sdk> <destination> <logfile>
set -uo pipefail

SCHEME="$1"; SDK="$2"; DEST="$3"; LOG="$4"

xcodebuild \
  -project StreamForge.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk "$SDK" \
  -destination "$DEST" \
  -derivedDataPath build \
  -clonedSourcePackagesDirPath .build/spm \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SF_TMDB_KEY="${SF_TMDB_KEY:-}" SF_OMDB_KEY="${SF_OMDB_KEY:-}" \
  build > "$LOG" 2>&1
STATUS=$?

# Compiler/linker errors -> annotations (readable via the Checks API).
grep -E "(^/.+:[0-9]+:[0-9]+: error: )|(^ld: )|(error: )" "$LOG" \
  | grep -v "^note:" | sort -u | head -60 > errors.txt || true

COUNT=$(wc -l < errors.txt | tr -d ' ')
echo "xcodebuild exit: $STATUS, error lines: $COUNT"

while IFS= read -r line; do
  if [[ "$line" =~ ^(/[^:]+):([0-9]+):([0-9]+):\ error:\ (.*)$ ]]; then
    file="${BASH_REMATCH[1]#"$GITHUB_WORKSPACE/"}"
    echo "::error file=${file},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[4]}"
  else
    echo "::error::${line:0:900}"
  fi
done < errors.txt

if [[ $STATUS -ne 0 && $COUNT -eq 0 ]]; then
  # No parseable error: surface the tail so the cause is visible.
  tail -40 "$LOG" | while IFS= read -r l; do echo "::error::${l:0:900}"; done
fi

{
  echo "### $SCHEME ($SDK): exit $STATUS"
  echo '```'
  head -60 errors.txt
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit $STATUS
