#!/usr/bin/env bash
# Diagóstico de cuelgue del proceso navegador (Chromper) con una URL concreta.
#
# Uso (en la máquina donde se cuelga):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/dr0per250/ungoogled-chromium-ucsync/master/ucsync/diag_hang.sh)"
#   # o con args: URL=... PREFIX=... bash diag_hang.sh
#
# Lanza Chromper con log, te deja reproducir el cuelgue y recoge dónde está bloqueado el
# proceso: hilos, wchan, pila de gdb (si está) y una traza corta de syscalls.
# Salida: /tmp/chromper-hang-<marca>.txt  -> pégame ese fichero.
set -uo pipefail
URL="${URL:-http://10.7.93.10:30177/}"
BIN="${BIN:-$HOME/.local/share/chromper/chromper}"
MARCA="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/chromper-hang-$MARCA.txt"
PERFIL="/tmp/chromper-hang-perfil-$MARCA"
LOG="/tmp/chromper-hang-$MARCA.log"

command -v gdb >/dev/null 2>&1 || echo "aviso: gdb no está instalado (sudo pacman -S gdb) -> se usará /proc y strace"
[[ -x "$BIN" ]] || { echo "no existe $BIN (puedes dar BIN=/ruta/chromper)"; exit 1; }

echo "== lanzando $BIN con $URL (log en $LOG)"
"$BIN" --enable-logging=stderr --v=0 --user-data-dir="$PERFIL" --class=chromper "$URL" >"$LOG" 2>&1 &
CPID=$!
echo "   pid del proceso navegador: $CPID"
echo
echo " reproduce el cuelgue (abre la página, pulsa '+', espera a que las ventanas dejen de responder )"
read -r -p " cuando esté colgado, pulsa ENTER para recoger el diagnóstico... "

{
  echo "### chromper-hang $MARCA"
  echo "url=$URL  bin=$BIN  perfil=$PERFIL"
  echo "binario: $(stat -c '%s bytes  %y' "$BIN")"
  echo "== proceso principal =="
  ps -o pid,ppid,stat,etime,wchan:28,comm -p "$CPID" 2>/dev/null
  echo "== hilos del navegador =="
  ps -T -p "$CPID" -o tid,stat,wchan:28,comm 2>/dev/null | head -40
  echo "== estado de cada hilo (wchan/syscall) =="
  for t in /proc/$CPID/task/*; do
    printf '%s ' "$(basename "$t")"
    cat "$t/wchan" 2>/dev/null | tr -d '\0'; printf ' | '
    cat "$t/syscall" 2>/dev/null | head -c 60; printf ' | '
    head -3 "$t/status" 2>/dev/null | tr '\n' ' '; echo
  done | head -40
  echo "== procesos chromper/child vivos =="
  pgrep -a chromper | head -20
  echo "== volcados de crashpad =="
  ls -l "$PERFIL/Crashpad/completed" 2>/dev/null | head -5
  echo "== últimas 60 líneas del log =="
  tail -60 "$LOG"
  echo "== backtrace (gdb) =="
  if command -v gdb >/dev/null 2>&1; then
    sudo -n gdb -p "$CPID" -batch -ex "thread apply all bt" 2>&1 | head -200 ||
      echo "gdb necesita sudo interactivo: ejecuta tu mismo  sudo gdb -p $CPID -batch -ex 'thread apply all bt' | head -200"
  else
    echo "gdb ausente"
  fi
  echo "== ¿sigue vivo tras 20 s? =="
  sleep 20
  ps -o pid,stat,wchan:28,comm -p "$CPID" 2>/dev/null || echo "el proceso ya no existe"
} >"$OUT" 2>&1

echo
echo "== diagnóstico escrito en $OUT =="
echo "   pégame el contenido de ese fichero (o pega  tail -80 $OUT )"
echo
echo "pruebas de aislamiento (cada una en una terminal, con perfil nuevo):"
echo "  chromper --ozone-platform=x11  --user-data-dir=/tmp/p-x11   $URL   # descarta ozone-wayland"
echo "  chromper --disable-gpu         --user-data-dir=/tmp/p-nogpu  $URL   # descarta el proceso GPU"
echo "  chromper --disable-extensions  --user-data-dir=/tmp/p-noext   $URL   # descarta las extensiones embebidas"
echo "  firefox $URL                                                      # si también se cuelga, es el servidor omp"
read -r -p " ¿mato el chromper lanzado? [S/n] " R
[[ "${R:-S}" != "n" ]] && kill "$CPID" 2>/dev/null
