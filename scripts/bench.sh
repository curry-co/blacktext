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

swift build -c release --product blktxt-bench >/dev/null
BIN=$(swift build -c release --show-bin-path)

if [ ! -f "$DB" ]; then
  echo "Seeding $YEARS years at $WORDS words a day → $DB"
  "$BIN/blktxt-bench" seed --db "$DB" --years "$YEARS" --words-per-day "$WORDS"
fi

echo
echo "Database"
"$BIN/blktxt-bench" measure --db "$DB" || STATUS=$?

APP=build/BlackText.app/Contents/MacOS/BlackText
if [ -x "$APP" ]; then
  echo
  echo "App (process start → window drawn with the cursor in the note; median of 5)"
  launches=()
  quits=()
  for _ in 1 2 3 4 5; do
    out=$(BLKTXT_DB="$DB" BLKTXT_LAUNCH_TRACE=1 BLKTXT_EXIT_AFTER_LAUNCH=1 "$APP" 2>&1 || true)
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
