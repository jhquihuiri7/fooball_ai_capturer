#!/bin/bash
# Corre DENTRO del pod (lo copia y lo llama tools/pod.sh). Enciende y apaga el servidor:
#   MediaMTX   recibe el RTMP de los dos móviles en el 1935, con usuario y clave
#   panel      football-ai con dos cámaras e IA en GPU, solo en 127.0.0.1:8090
#   nginx      abre el panel a internet en el 8091, con usuario y clave
#   relé       a YouTube/Facebook, solo si hay clave en /root/football-ai/rele.env
#
#   /root/football-ai/servicios.sh start | stop | status
cd /root/football-ai || exit 1
SERVER=/root/servidor
PITCH_LIMITS="${PITCH_LIMITS:--45 35}"
FLIP="${FLIP-left}"

# En segundo plano sin quedarse con la sesión SSH que lo lanzó.
bg() { local log="$1"; shift; nohup "$@" > "$log" 2>&1 < /dev/null & }

# El panel no arranca si a una cámara todavía no le llega señal. Un relleno negro, sin
# código de tiempo, ocupa el canal hasta que entra el móvil, que lo desplaza solo
# (MediaMTX deja que un publicador nuevo sustituya al anterior). Se lanza una vez y NO se
# relanza: relanzado desplazaría él al móvil.
relleno() {
  bg "relleno-$1.log" ffmpeg -hide_banner -loglevel error -re -f lavfi \
    -i "color=c=black:s=3840x2160:r=5" -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 5 -pix_fmt yuv420p -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/rig/$1"
}

case "${1:-status}" in
  start)
    pgrep -x mediamtx >/dev/null || { bg mediamtx.log ./mediamtx mediamtx.yml; sleep 2; relleno izquierda; relleno derecha; sleep 3; }

    ARGS="rtsp://127.0.0.1:8554/rig/izquierda --right-url rtsp://127.0.0.1:8554/rig/derecha"
    ARGS="$ARGS --rig /root/football-ai/soporte.json --rig-pitch-limits $PITCH_LIMITS"
    [ -n "$FLIP" ] && ARGS="$ARGS --flip $FLIP"
    [ -f "$SERVER/models/onnx/rfdetr-small.onnx" ] && ARGS="$ARGS --model models/onnx/rfdetr-small.onnx"
    [ -f rele.env ] && ARGS="$ARGS --publish rtmp://127.0.0.1:1935/salida --bitrate ${BITRATE:-6}"
    ARGS="$ARGS --port 8090 --no-browser --open-timeout 30 --read-timeout 30"
    # `bucle-panel` es solo una marca para encontrar el bucle con pgrep/pkill.
    # El QR de las camaras del panel: la direccion publica del RTMP, que solo conoce quien
    # despliega (tools/pod.sh la pasa en FOOTBALL_CAMERA_URL). Se guarda para los
    # arranques siguientes, en un fichero que solo lee root.
    if [ -n "${FOOTBALL_CAMERA_URL:-}" ]; then
      (umask 077; printf '%s\n' "$FOOTBALL_CAMERA_URL" > camera.url)
    fi
    [ -f camera.url ] && export FOOTBALL_CAMERA_URL="$(cat camera.url)"
    pgrep -f bucle-panel >/dev/null || bg panel.log bash -c ": bucle-panel; cd $SERVER && while true; do uv run --group gpu --locked python tools/live_panel.py $ARGS; sleep 3; done"

    if [ -f rele.env ]; then
      pgrep -f stream_relay.py >/dev/null || bg rele.log bash -c "set -a; . /root/football-ai/rele.env; set +a; cd $SERVER && exec uv run --group gpu --locked python tools/stream_relay.py"
    fi

    # Instancia propia de nginx: la de la imagen de RunPod no se toca.
    [ -f /run/nginx-panel.pid ] && kill -0 "$(cat /run/nginx-panel.pid)" 2>/dev/null || nginx -c /root/football-ai/nginx-panel.conf
    echo encendido
    ;;
  stop)
    pkill -f bucle-panel; pkill -f live_panel.py; pkill -f stream_relay.py; pkill -f "lavfi"
    pkill -x mediamtx; [ -f /run/nginx-panel.pid ] && kill "$(cat /run/nginx-panel.pid)" 2>/dev/null
    echo apagado
    ;;
  status)
    for p in mediamtx live_panel.py stream_relay.py nginx-panel; do
      pgrep -f "$p" >/dev/null && echo "  $p: ENCENDIDO" || echo "  $p: apagado"
    done
    echo "  móviles:"; grep -E "RTMP.*is publishing to path 'rig/" mediamtx.log 2>/dev/null | tail -2 | sed 's/^/    /' | cut -c1-140
    nvidia-smi --query-gpu=name,utilization.gpu --format=csv,noheader 2>/dev/null | sed 's/^/  GPU: /'
    ;;
  *) echo "uso: servicios.sh start | stop | status"; exit 1 ;;
esac
