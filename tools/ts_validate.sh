#!/usr/bin/env bash
# Valida un MPEG-TS del multiplexor (IOS-53) con ffprobe en el Mac: sin errores, PTS
# monótonos por flujo y la sincronía A/V del arranque por debajo de 20 ms.
#
#   tools/ts_validate.sh programa.ts
#
# TsMuxerTests deja uno de 10 s en $TMPDIR/ios53-diez-segundos.ts.
set -euo pipefail
ts="${1:?uso: tools/ts_validate.sh fichero.ts}"
errores=$(ffprobe -v error -show_packets "$ts" 2>&1 >/dev/null || true)
if [ -n "$errores" ]; then
  echo "ffprobe se queja:"; echo "$errores"; exit 1
fi
ffprobe -v error -show_entries packet=stream_index,pts_time -of csv=p=0 "$ts" | awk -F, '
  { if (($1 in ultimo) && $2 <= ultimo[$1]) { print "PTS no monótono en el flujo " $1 ": " $2; malo = 1 }
    ultimo[$1] = $2; if (!($1 in primero)) primero[$1] = $2 }
  END {
    if (!(0 in primero) || !(1 in primero)) { print "faltan vídeo o audio"; exit 1 }
    d = primero[0] - primero[1]; if (d < 0) d = -d
    printf "A/V al arranque: %.1f ms\n", d * 1000
    if (d >= 0.020 || malo) exit 1
    print "ok"
  }'
