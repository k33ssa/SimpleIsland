#!/bin/bash
# Сборка SimpleIslandMR.dylib — библиотеки «что играет» модуля «Медиа» (её грузит /usr/bin/perl, docs/TECH.md §1).
# Использование: scripts/build-media-helper.sh [каталог]
#   по умолчанию — каталог отладочного бинарника `.build-main` (там же, где `.build-main/debug/SimpleIsland`, чтобы
#   `--selftest-media` проверял помощника); свой scratch — SIMPLEISLAND_SCRATCH.
# Модуль ищет библиотеку: $SIMPLEISLAND_MR_DYLIB → .app/Contents/Resources → каталог исполняемого файла.
# Подпись здесь ad-hoc; в .app её переподписывает scripts/build-app.sh той же идентичностью, что и бандл.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Приоритет — как в build-app.sh: `nice -n 5` (taskpolicy -b под нагрузкой душит сборку), своё — SIMPLEISLAND_PRIO.
read -r -a PRIO <<< "${SIMPLEISLAND_PRIO:-nice -n 5}"
if [ $# -ge 1 ]; then
  OUT="$1"
else
  OUT="$(cd "$ROOT" && swift build -j 2 --scratch-path "${SIMPLEISLAND_SCRATCH:-.build-main}" --show-bin-path)"
fi
SRC="$ROOT/Helpers/MediaRemote/SimpleIslandMR.m"
mkdir -p "$OUT"
# clang с двумя -arch оставляет в $TMPDIR пустые каталоги `SimpleIslandMR-xxxxxx` (по 4 на сборку, 14.11) —
# даём ему свой временный каталог и убираем его на выходе.
CLANG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/simpleisland-mr-build.XXXXXX")"
trap 'rm -rf "$CLANG_TMP"' EXIT
TMPDIR="$CLANG_TMP" "${PRIO[@]}" xcrun clang -dynamiclib -fobjc-arc -O2 -Wall -Wno-unused-function \
  -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework Foundation -framework ImageIO -framework CoreGraphics -o "$OUT/SimpleIslandMR.dylib" "$SRC"
codesign --force --sign - "$OUT/SimpleIslandMR.dylib" >/dev/null 2>&1 || true
echo "→ $OUT/SimpleIslandMR.dylib"
