#!/bin/bash
# Lists English UI text with no Danish translation, and Danish entries nothing uses any more.
# The compiler finds every translatable string: SwiftUI literals and String(localized:).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/.build/localization"
rm -rf "$out/strings"; mkdir -p "$out/strings"
swift build --disable-sandbox --scratch-path "$out/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$out/strings" >/dev/null
plutil -convert json -o "$out/da.json" Resources/da.lproj/Localizable.strings
python3 - "$out" <<'PY'
import json, glob, sys, re
out = sys.argv[1]
keys = {}
for f in glob.glob(out + '/strings/*.stringsdata'):
    d = json.load(open(f))
    if 'SmokeTest' in d['source']: continue
    for table in d.get('tables', {}).values():
        for e in table: keys.setdefault(e['key'], f"{d['source'].split('/Sources/Brim/')[-1]}:{e['location']['startingLine']}")
da = json.load(open(out + '/da.json'))
spec = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|@|lf|f)|%%')
norm = lambda s: sorted(re.sub(r'\d+\$', '', m) for m in spec.findall(s))
missing = sorted(k for k in keys if k not in da)
unused = sorted(k for k in da if k not in keys)
mismatched = sorted(k for k in da if k in keys and norm(k) != norm(da[k]))
for k in missing: print(f"missing  {keys[k]}  {k!r}")
for k in unused: print(f"unused   {k!r}")
for k in mismatched: print(f"placeholders differ  {k!r}")
print(f"{len(keys)} strings · {len(missing)} missing · {len(unused)} unused · {len(mismatched)} placeholder mismatches")
sys.exit(1 if missing or mismatched else 0)
PY
