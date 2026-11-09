#!/bin/bash
# Prints the id of the first available iOS Simulator whose name matches one of the arguments, in order:
# an exact name, or the start of one ("iPad Pro 13-inch" matches "iPad Pro 13-inch (M5)").
# Prints nothing if none matches. Usage: scripts/pick-simulator.sh "iPhone 17 Pro Max" "iPhone 16 Pro Max"
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for runtime, ds in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in ds]
for wanted in sys.argv[1:]:
    match = [d for d in devices if d["name"] == wanted] or [d for d in devices if d["name"].startswith(wanted)]
    if match:
        print(match[-1]["udid"])
        break
' "$@"
