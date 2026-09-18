#!/bin/bash
# El servidor entero en este Mac, para probar sin pagar el pod: MediaMTX (el buzón que
# recibe a los móviles), su anuncio Bonjour (para que la app lo encuentre sola) y el panel
# de `football-ai` leyendo la cámara izquierda.
#
#   tools/local.sh start          # enciende y abre el panel en el navegador
#   tools/local.sh start clip     # lo mismo, con un vídeo grabado haciendo de iPhone
#   tools/local.sh stop           # apaga todo
#   tools/local.sh status         # qué está encendido y cuánta CPU gasta
#
# Con `start` a secas el panel espera a que el iPhone emita: abrir la app, IZQUIERDA,
# GRABAR. Con `start clip` no hace falta el móvil, pero solo puede publicar uno a la vez
# en el canal: para pasar al iPhone de verdad, `stop` y `start`.
#
# El panel decodifica y compone 4K: ocupa unos tres núcleos. Apagarlo al terminar.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_REPO="${SERVER_REPO:-$REPO/../fooball_ai_streaming}"
CLIP="${CLIP:-$HOME/Movies/football-ai/iphone-izquierda.mov}"
RUN="${TMPDIR:-/tmp}/football-ai-local"
PANEL_URL="http://127.0.0.1:8090"
CHANNEL="rig/izquierda"

mkdir -p "$RUN"

running() { [ -f "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; }

launch() {  # nombre, comando...
  local name="$1"; shift
  if running "$name"; then echo "  $name ya estaba encendido"; return; fi
  nohup "$@" > "$RUN/$name.log" 2>&1 &
  echo $! > "$RUN/$name.pid"
  echo "  $name encendido (log: $RUN/$name.log)"
}

halt() {
  local name="$1"
  if running "$name"; then
    kill "$(cat "$RUN/$name.pid")" 2>/dev/null
    echo "  $name apagado"
  fi
  rm -f "$RUN/$name.pid"
}

case "${1:-status}" in
  start)
    for tool in mediamtx uv; do
      command -v "$tool" >/dev/null || { echo "falta $tool: brew install $tool"; exit 1; }
    done
    [ -d "$SERVER_REPO" ] || { echo "no encuentro el servidor en $SERVER_REPO (usa SERVER_REPO=...)"; exit 1; }

    echo "Encendiendo el servidor local:"
    cd "$REPO" || exit 1
    launch mediamtx mediamtx tools/mediamtx-banco.yml
    launch anuncio dns-sd -R "$(scutil --get LocalHostName)" _footballai-srt._tcp . 8890
    sleep 2

    if [ "${2:-}" = "clip" ]; then
      command -v ffmpeg >/dev/null || { echo "falta ffmpeg: brew install ffmpeg"; exit 1; }
      [ -f "$CLIP" ] || { echo "no encuentro el clip $CLIP (usa CLIP=...)"; exit 1; }
      # Sin recodificar: llega lo mismo que mandaría el móvil, HEVC 4K con su código de tiempo.
      launch clip ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i "$CLIP" \
        -an -c:v copy -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/$CHANNEL"
      sleep 2
    fi

    # El panel se cierra si al arrancar nadie emite todavía (MediaMTX responde 404), así
    # que se relanza solo hasta que llegue la señal. El navegador se abre en ese momento.
    launch panel bash -c "cd '$SERVER_REPO' && while true; do uv run python tools/live_panel.py 'rtsp://127.0.0.1:8554/$CHANNEL' --port 8090 --no-browser --open-timeout 30 --read-timeout 30; sleep 3; done"
    launch abrir bash -c "until curl -s -m 1 -o /dev/null '$PANEL_URL'; do sleep 2; done; open '$PANEL_URL'"
    echo "Panel: $PANEL_URL (se abre solo en el navegador cuando haya señal)"
    echo "IP de este Mac para la app: $(ipconfig getifaddr en0 2>/dev/null || echo '?') (la app la encuentra sola)"
    [ "${2:-}" = "clip" ] || echo "Ahora en el iPhone: abrir la app, IZQUIERDA, GRABAR."
    ;;
  stop)
    echo "Apagando el servidor local:"
    for name in abrir panel clip anuncio mediamtx; do halt "$name"; done
    # El panel corre como hijo del bucle que lo relanza: se le busca por su línea de comando.
    pkill -f '[l]ive_panel.py' 2>/dev/null
    echo "Listo."
    ;;
  status)
    for name in mediamtx anuncio clip panel; do
      if running "$name"; then echo "  $name: ENCENDIDO"; else echo "  $name: apagado"; fi
    done
    if running panel && ! curl -s -m 1 -o /dev/null "$PANEL_URL"; then
      echo "  (el panel está esperando a que el iPhone emita)"
    fi
    ps -Ao pcpu,comm,args | grep -E '[l]ive_panel|[m]ediamtx tools|ffmpeg.*[r]ig/' | awk '{printf "  CPU %5s%%  %s\n", $1, $2}'
    ;;
  *)
    echo "uso: tools/local.sh start [clip] | stop | status"; exit 1
    ;;
esac
