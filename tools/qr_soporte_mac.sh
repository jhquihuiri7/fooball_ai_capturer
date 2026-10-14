#!/bin/bash
# El QR Soporte de un VPS de pruebas en el Mac (IOS-58): el MediaMTX de
# tools/mediamtx-programa.yml en esta IP, con el mismo `support_payload` que sirve /pair en
# el VPS (football-ai, tools/nube/pairing.py). Se escanea en la tarjeta «VPS» de la pantalla
# de lado de cada iPhone y EMITIR publica al Mac sin lanzar nada desde aquí.
#
#   tools/qr_soporte_mac.sh <fichero_passphrase> [salida.svg]
#
# <fichero_passphrase>: la passphrase SRT con la que se arrancó MediaMTX (10-79 caracteres
# de [A-Za-z0-9._-]; `openssl rand -hex 16` da 32). No se imprime. El usuario y la clave
# del programa son de prueba (MediaMTX acepta cualquiera desde la LAN). El `rig_key` va
# firmado con un secreto al azar: el túnel no existe en el Mac y no se usa.
#
# El SVG lleva la passphrase: se escribe con permisos 600 fuera del repo, en $TMPDIR, y hay
# que borrarlo al acabar.
set -euo pipefail

FRASE=$(cd "$(dirname "${1:?fichero con la passphrase SRT}")" && pwd)/$(basename "$1")
SALIDA=${2:-${TMPDIR:-/tmp}/qr-soporte-mac.svg}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
REFERENCIA=${REFERENCIA:-$RAIZ/../fooball_ai_streaming}
IP=${IP:-$(ipconfig getifaddr en0)}

umask 077
case "$SALIDA" in /*) ;; *) SALIDA="$PWD/$SALIDA" ;; esac
# Desde la raíz de football-ai, para que `tools` sea el suyo y no el de este repo.
cd "$REFERENCIA"
FOOTBALL_VPS_DOMAIN="$IP" FOOTBALL_PROGRAM_USER=maestro FOOTBALL_PROGRAM_PASSWORD=banco \
FOOTBALL_PROGRAM_PASSPHRASE="$(cat "$FRASE")" \
  uv run python - "$SALIDA" 2> >(grep -v '^objc\[' >&2) <<'PY'
import json, os, secrets, sys, time
from pathlib import Path

from tools.nube.pairing import SupportCredentials, qr_svg, support_payload

creds = SupportCredentials.from_env(os.environ)
datos = support_payload(creds, secret=secrets.token_bytes(32), generation=1, now_s=int(time.time()))
Path(sys.argv[1]).write_bytes(qr_svg(json.dumps(datos, separators=(",", ":"))))
srt = datos["srt"]
print(f"QR Soporte de {srt['host']}:{srt['port']} en {sys.argv[1]} (caduca en 12 h)")
PY
