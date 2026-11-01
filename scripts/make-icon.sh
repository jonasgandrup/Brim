#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift scripts/make-icon.swift .build/Brim.iconset
# Encode standard PNG-backed ICNS entries directly; no GUI or asset compiler required.
python3 - <<'PY'
from pathlib import Path
import struct
root = Path('.build/Brim.iconset')
entries = [('icp4', 'icon_16x16.png'), ('icp5', 'icon_32x32.png'),
           ('icp6', 'icon_32x32@2x.png'), ('ic07', 'icon_128x128.png'),
           ('ic08', 'icon_256x256.png'), ('ic09', 'icon_512x512.png'),
           ('ic10', 'icon_512x512@2x.png'), ('ic11', 'icon_16x16@2x.png'),
           ('ic12', 'icon_32x32@2x.png'), ('ic13', 'icon_128x128@2x.png'),
           ('ic14', 'icon_256x256@2x.png')]
chunks = b''.join(kind.encode() + struct.pack('>I', len(data) + 8) + data
                  for kind, name in entries for data in [(root / name).read_bytes()])
Path('Resources/Brim.icns').write_bytes(b'icns' + struct.pack('>I', len(chunks) + 8) + chunks)
PY
