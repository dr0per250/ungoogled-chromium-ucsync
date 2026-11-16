#!/usr/bin/env bash
# Trae el Go que Dawn necesita para sus enlaces de Node.
#
# Dawn lo espera en `third_party/dawn/tools/golang/<os>-<arch>/bin/go` y lo describe en su
# propio `DEPS` (repositorio anidado), que gclient no procesa: sin esto el build se cae con
# `FileNotFoundError: .../tools/golang/linux-amd64/bin/go` a mitad de la compilación.
set -euo pipefail
SRC="${1:-/IA/chromium-build/src}"
DEST="$SRC/third_party/dawn/tools/golang/linux-amd64"
CIPD="${CIPD:-$(command -v cipd || echo /IA/chromium-build/depot_tools/cipd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"
printf 'infra/3pp/tools/go/linux-amd64 latest\n' > "$TMP/go.ensure"
"$CIPD" ensure -root "$DEST" -ensure-file "$TMP/go.ensure" >/dev/null
"$DEST/bin/go" version
