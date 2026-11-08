#!/bin/bash
# Seeds a database that looks like years of heavy use, then measures BlackText against it.
#   scripts/bench.sh                    10 years at 10,000 words a day
#   YEARS=1 WORDS=2000 scripts/bench.sh  something quicker
set -euo pipefail
cd "$(dirname "$0")/.."

YEARS=${YEARS:-10}
WORDS=${WORDS:-10000}
DB=${BENCH_DB:-bench/bench-${YEARS}y-${WORDS}w.sqlite}
mkdir -p "$(dirname "$DB")"

swift build -c release --product blacktext-bench >/dev/null
BIN=$(swift build -c release --show-bin-path)

# A database seeded before the tool marked its own (with DB.bench) is replaced only in the default place.
if [ ! -f "$DB.bench" ]; then
  echo "Seeding $YEARS years at $WORDS words a day → $DB"
  replace=()
  if [ -z "${BENCH_DB:-}" ]; then replace=(--replace); fi
  "$BIN/blacktext-bench" seed --db "$DB" --years "$YEARS" --words-per-day "$WORDS" ${replace[@]+"${replace[@]}"}
fi

echo
echo "Database"
"$BIN/blacktext-bench" measure --db "$DB" || STATUS=$?

BUNDLE=build/BlackText.app
APP=$BUNDLE/Contents/MacOS/BlackText
# Release builds sync with iCloud. Newer ones never sync a BLACKTEXT_DB database, but older ones do, so
# never launch a release build against the benchmark: its notes would end up in the real account.
syncs() {
  case "$(/usr/libexec/PlistBuddy -c "Print :BlackTextCloudSync" "$BUNDLE/Contents/Info.plist" 2>/dev/null)" in
    true|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}
if [ -x "$APP" ] && syncs; then
  echo
  echo "(build/BlackText.app is a release build, which syncs with iCloud. Run make app for one to time.)"
elif [ -x "$APP" ]; then
  echo
  echo "App (process start → window drawn with the cursor in the note; median of 5)"
  launches=()
  quits=()
  for _ in 1 2 3 4 5; do
    out=$(BLACKTEXT_DB="$DB" BLACKTEXT_LAUNCH_TRACE=1 BLACKTEXT_EXIT_AFTER_LAUNCH=1 "$APP" 2>&1 || true)
    launches+=("$(echo "$out" | sed -n 's/.*launch_ms=\([0-9.]*\).*/\1/p')")
    quits+=("$(echo "$out" | sed -n 's/.*quit_ms=\([0-9.]*\).*/\1/p')")
  done
  median() { printf '%s\n' "$@" | sort -n | sed -n '3p'; }
  echo "  Launch                                       $(median "${launches[@]}") ms   (target 200 ms)"
  echo "  Quit                                         $(median "${quits[@]}") ms   (target 50 ms)"
else
  echo "(Run make app first to time the app's launch.)"
fi
exit ${STATUS:-0}
