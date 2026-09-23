#!/bin/bash
# El servidor entero en este Mac, para probar sin pagar el pod: MediaMTX (el buzón que
# recibe a los móviles), su anuncio Bonjour (para que la app lo encuentre sola) y el panel
# de `football-ai` leyendo la cámara izquierda.
#
#   tools/local.sh start          # enciende y abre el panel en el navegador
#   tools/local.sh start clip     # lo mismo, con un vídeo grabado haciendo de iPhone
#   tools/local.sh start dos      # los dos iPhone: el panel junta izquierda y derecha
#   tools/local.sh stop           # apaga todo
#
# Para salir a YouTube (o Facebook), la clave va SOLO por variable de entorno, nunca en un
# fichero: FBAI_YOUTUBE_KEY=xxxx tools/local.sh start dos
# El panel publica entonces el programa y el relé del servidor le añade audio y lo sube.
# El botón «al aire» del panel corta y reanuda la salida.
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

    # Relleno: el panel no arranca (y su página no abre) si a una cámara aún no le llega
    # señal. Un vídeo negro sin código de tiempo ocupa el canal hasta que entra el móvil,
    # que lo desplaza solo (MediaMTX deja que un publicador nuevo sustituya al anterior).
    # Se lanza una vez y no se relanza: relanzado desplazaría él al móvil.
    if [ "${2:-}" != "clip" ] && command -v ffmpeg >/dev/null; then
      LADOS="izquierda"; [ "${2:-}" = "dos" ] && LADOS="izquierda derecha"
      for lado in $LADOS; do
        launch "relleno-$lado" ffmpeg -hide_banner -loglevel error -re -f lavfi \
          -i "color=c=black:s=3840x2160:r=5" -c:v libx264 -preset ultrafast -tune zerolatency \
          -g 5 -pix_fmt yuv420p -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/rig/$lado"
      done
      sleep 3
    fi

    # El panel se cierra si al arrancar nadie emite todavía (MediaMTX responde 404), así
    # que se relanza solo hasta que llegue la señal. El navegador se abre en ese momento.
    # Con `dos`, el panel lee también la cámara derecha y guarda la calibración del soporte.
    RIG_ARGS=""
    if [ "${2:-}" = "dos" ]; then
      mkdir -p "$HOME/Movies/football-ai"
      # El soporte monta el móvil izquierdo girado 180° para juntar las lentes: su imagen
      # llega cabeza abajo y el panel la endereza. `FLIP=right` o `FLIP=` si cambia el montaje.
      FLIP="${FLIP-left}"
      RIG_ARGS="--right-url 'rtsp://127.0.0.1:8554/rig/derecha' --rig '$HOME/Movies/football-ai/soporte.json'"
      [ -n "$FLIP" ] && RIG_ARGS="$RIG_ARGS --flip $FLIP"
      # Banda vertical de la panorámica. Por defecto la de una cancha desde un mástil, que
      # recorta el cielo; en interior: PITCH_LIMITS="-45 35" tools/local.sh start dos
      [ -n "${PITCH_LIMITS:-}" ] && RIG_ARGS="$RIG_ARGS --rig-pitch-limits $PITCH_LIMITS"
    fi
    # La IA (cajas de jugadores) se enciende sola si está el modelo del socio. No viene
    # en git: hay que pedírselo y dejarlo en models/onnx/ del repo del servidor.
    MODEL="${MODEL-$SERVER_REPO/models/onnx/rfdetr-small.onnx}"
    if [ -n "$MODEL" ] && [ -f "$MODEL" ]; then
      RIG_ARGS="$RIG_ARGS --model '$MODEL'"
      echo "IA: con modelo ($(basename "$MODEL"))"
    else
      echo "IA: APAGADA, falta $MODEL"
    fi
    # La cámara virtual (el programa sigue a los jugadores y hace los planos) necesita las
    # dos cámaras, el soporte calibrado y el modelo. `DIRECTOR=` la apaga y sale la
    # panorámica entera, que es lo que hace falta ver para montar y calibrar el soporte.
    DIRECTOR="${DIRECTOR-1}"
    if [ -n "$DIRECTOR" ] && [ "${2:-}" = "dos" ] && [ -f "$MODEL" ] && [ -f "$HOME/Movies/football-ai/soporte.json" ]; then
      RIG_ARGS="$RIG_ARGS --director"
      echo "Cámara virtual: ENCENDIDA (DIRECTOR= tools/local.sh start dos la apaga)"
    else
      echo "Cámara virtual: apagada (sale la panorámica entera)"
    fi
    # Vídeos de prueba, clips y repeticiones, en ~/Movies/football-ai. Con soporte, un
    # vídeo subido desde el panel se parte en las dos cámaras y se publica con su código
    # de tiempo, así que se puede probar entero sin los móviles. Ojo: ese vídeo no está
    # girado, así que para usarlo hay que apagar el enderezado con FLIP= (ver arriba).
    TRABAJO="$HOME/Movies/football-ai"
    mkdir -p "$TRABAJO/videos" "$TRABAJO/clips" "$TRABAJO/buffer"
    RIG_ARGS="$RIG_ARGS --videos '$TRABAJO/videos' --clips '$TRABAJO/clips'"
    RIG_ARGS="$RIG_ARGS --replay-buffer '$TRABAJO/buffer'"

    # Con clave de alguna plataforma, el panel publica el programa para el relé.
    RELAY=""
    if [ -n "${FBAI_YOUTUBE_KEY:-}${FBAI_FACEBOOK_KEY:-}${FBAI_TIKTOK_KEY:-}" ]; then
      command -v ffmpeg >/dev/null || { echo "falta ffmpeg: brew install ffmpeg"; exit 1; }
      RELAY=1
      RIG_ARGS="$RIG_ARGS --publish rtmp://127.0.0.1:1935/salida --bitrate ${BITRATE:-6}"
    fi
    # El panel enseña abajo un QR con esto: lo que va en «Servidor» de la app (host = SRT).
    export FOOTBALL_CAMERA_URL="${FOOTBALL_CAMERA_URL:-$(ipconfig getifaddr en0 2>/dev/null)}"
    launch panel bash -c "cd '$SERVER_REPO' && while true; do uv run python tools/live_panel.py 'rtsp://127.0.0.1:8554/$CHANNEL' $RIG_ARGS --port 8090 --no-browser --open-timeout 30 --read-timeout 30; sleep 3; done"
    if [ -n "$RELAY" ]; then
      # Las claves las hereda del entorno; en el log salen tapadas.
      launch rele bash -c "cd '$SERVER_REPO' && exec uv run python tools/stream_relay.py"
    fi
    launch abrir bash -c "until curl -s -m 1 -o /dev/null '$PANEL_URL'; do sleep 2; done; open '$PANEL_URL'"
    echo "Panel: $PANEL_URL (se abre solo en el navegador cuando haya señal)"
    echo "IP de este Mac para la app: $(ipconfig getifaddr en0 2>/dev/null || echo '?') (la app la encuentra sola)"
    [ "${2:-}" = "clip" ] || echo "Ahora en el iPhone: abrir la app, IZQUIERDA, GRABAR."
    ;;
  stop)
    echo "Apagando el servidor local:"
    for name in rele abrir panel clip relleno-izquierda relleno-derecha anuncio mediamtx; do halt "$name"; done
    pkill -f '[s]tream_relay.py' 2>/dev/null
    # El panel corre como hijo del bucle que lo relanza: se le busca por su línea de comando.
    pkill -f '[l]ive_panel.py' 2>/dev/null
    echo "Listo."
    ;;
  status)
    for name in mediamtx anuncio clip panel rele; do
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
