#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Stop only the executable from this checkout before replacing it.
process_pattern="$(python3 -c 'import re, sys; print("^" + re.escape(sys.argv[1]) + "( |$)")' "$PWD/dist/Sense.app/Contents/MacOS/Sense")"
/usr/bin/pkill -f "$process_pattern" 2>/dev/null || true
./build.sh debug
open "$PWD/dist/Sense.app" --args --settings
