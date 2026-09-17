#!/bin/sh
# El banco de pruebas en el Mac: MediaMTX recibiendo a los móviles, anunciado por Bonjour
# para que la app lo encuentre sola y nadie tenga que teclear una IP.
#
#   tools/banco.sh            # arranca MediaMTX y el anuncio; Ctrl-C para parar los dos
#
# Comprobar lo que llega, desde el repo del servidor:
#   uv run python tools/ingest_probe.py probe rtsp://127.0.0.1:8554/izquierda --seconds 20
set -eu
cd "$(dirname "$0")/.."

# `_footballai-srt._tcp` es el tipo que busca la app (ver `ServerDiscovery.swift` y
# `NSBonjourServices` en Info.plist). El nombre es el del Mac, para saber cuál es.
dns-sd -R "$(scutil --get LocalHostName)" _footballai-srt._tcp . 8890 >/dev/null 2>&1 &
ADVERT=$!
trap 'kill $ADVERT 2>/dev/null' EXIT INT TERM

exec mediamtx tools/mediamtx-banco.yml
