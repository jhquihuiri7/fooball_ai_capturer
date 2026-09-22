#!/bin/bash
# El servidor entero en un pod de RunPod con GPU, desde cero y con un solo comando.
#
#   tools/pod.sh up        # crea UN pod, instala todo, lo enciende y dice a dónde conectarse
#   tools/pod.sh status    # qué hay encendido, quién emite, cuánto cuesta
#   tools/pod.sh info      # vuelve a enseñar las direcciones y las claves
#   tools/pod.sh ssh       # una terminal dentro del pod
#   tools/pod.sh down      # BORRA el pod (deja de cobrar). Hay que confirmarlo.
#
# Por qué «desde cero» cada vez: el pod no tiene volumen, y sin volumen RunPod borra el
# disco al pararlo. Lo único que se guarda entre una vez y otra son las claves, en
# ~/.football-ai/ de este Mac (fuera del repo), para no cambiarlas en cada despliegue. La IP
# y los puertos sí cambian con cada pod: hay que volver a escribirlos en los móviles.
#
# Nunca crea un segundo pod: si el de la última vez sigue existiendo, `up` lo reutiliza.
#
# Para salir a YouTube o Facebook, la clave va por variable de entorno, nunca en un fichero
# del repo:   FBAI_YOUTUBE_KEY=xxxx tools/pod.sh up
#
# RunPod no deja pasar UDP: los móviles emiten por RTMP (TCP), no por SRT.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_REPO="${SERVER_REPO:-$REPO/../fooball_ai_streaming}"
RIG_JSON="${RIG_JSON:-$HOME/Movies/football-ai/soporte.json}"
STATE_DIR="$HOME/.football-ai"
STATE="$STATE_DIR/pod.json"
SECRETS="$STATE_DIR/pod.env"
SSH_KEY="${SSH_KEY:-$HOME/.runpod/ssh/runpodctl-ssh-key}"

GPU="${GPU:-NVIDIA GeForce RTX 4090}"
IMAGE="${IMAGE:-runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404}"
POD_NAME="football-ai"
# 22 SSH · 1935 RTMP de los móviles · 8091 el panel (nginx con clave)
PORTS="22/tcp,1935/tcp,8091/tcp"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

field() { /usr/bin/python3 -c "import json,sys; print(json.load(open('$STATE')).get('$1',''))" 2>/dev/null || true; }

pod_ssh() { ssh -i "$SSH_KEY" -p "$(field ssh_port)" -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$STATE_DIR/known_hosts" -o ConnectTimeout=20 -o LogLevel=ERROR "root@$(field ip)" "$@"; }
pod_scp() { scp -q -i "$SSH_KEY" -P "$(field ssh_port)" -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$STATE_DIR/known_hosts" -o LogLevel=ERROR "$@"; }

# ¿Sigue existiendo el pod apuntado? (borrado desde la web, por ejemplo)
pod_exists() { [ -f "$STATE" ] && runpodctl pod get "$(field id)" >/dev/null 2>&1; }

secrets() {
  if [ ! -f "$SECRETS" ]; then
    printf 'RTMP_PASS=%s\nPANEL_PASS=%s\n' "$(openssl rand -hex 6)" "$(openssl rand -hex 4)" > "$SECRETS"
    chmod 600 "$SECRETS"
  fi
  # shellcheck disable=SC1090
  . "$SECRETS"
}

info() {
  secrets
  echo
  echo "  Pod $(field id) · $(field gpu) · \$$(field cost)/h mientras esté encendido"
  echo
  echo "  En los DOS iPhone, campo «Servidor»:"
  echo "      rtmp://rig:$RTMP_PASS@$(field ip):$(field rtmp_port)"
  echo
  echo "  Panel, desde cualquier sitio:"
  echo "      http://$(field ip):$(field panel_port)      usuario: panel   clave: $PANEL_PASS"
  echo
  echo "  Al terminar: tools/pod.sh down   (si no, sigue cobrando)"
}

case "${1:-status}" in
  up)
    for tool in runpodctl ssh scp openssl git; do
      command -v "$tool" >/dev/null || { echo "falta $tool"; exit 1; }
    done
    [ -d "$SERVER_REPO/.git" ] || { echo "no encuentro el servidor en $SERVER_REPO (usa SERVER_REPO=...)"; exit 1; }
    MODEL="$SERVER_REPO/models/onnx/rfdetr-small.onnx"
    [ -f "$MODEL" ] || echo "aviso: falta $MODEL, el pod arrancará sin IA"
    [ -f "$RIG_JSON" ] || echo "aviso: falta $RIG_JSON, habrá que calibrar desde el panel"
    secrets

    if pod_exists; then
      echo "Ya hay un pod ($(field id)): lo reutilizo, no creo otro."
      runpodctl pod start "$(field id)" >/dev/null 2>&1 || true
    else
      echo "Creando UN pod ($GPU)..."
      OUT="$(runpodctl pod create --name "$POD_NAME" --image "$IMAGE" --gpu-id "$GPU" --gpu-count 1 \
        --cloud-type SECURE --container-disk-in-gb 40 --ports "$PORTS" --wait --wait-timeout 10m 2>&1)" \
        || { echo "$OUT" | tail -5; echo "no se pudo crear el pod"; exit 1; }
      # La salida trae líneas de espera y después el JSON del pod.
      echo "$OUT" | /usr/bin/python3 -c "
import json, sys
text = sys.stdin.read()
pod = json.loads(text[text.index('{'):])
json.dump({'id': pod['id'], 'ip': pod['ssh']['ip'], 'ssh_port': pod['ssh']['port'],
           'cost': pod.get('costPerHr'), 'gpu': pod.get('machine', {}).get('gpuId', '')},
          open('$STATE', 'w'))"
      rm -f "$STATE_DIR/known_hosts"
    fi

    # Los puertos públicos los reparte RunPod; el pod los conoce por su entorno.
    MAP="$(pod_ssh 'tr "\0" "\n" < /proc/1/environ | grep -E "^RUNPOD_TCP_PORT_(1935|8091)="')"
    /usr/bin/python3 - "$MAP" <<PY
import json, sys
state = json.load(open('$STATE'))
for line in sys.argv[1].split():
    name, value = line.split('=')
    state['rtmp_port' if name.endswith('1935') else 'panel_port'] = int(value)
json.dump(state, open('$STATE', 'w'))
PY

    echo "Subiendo el servidor, el modelo y la calibración..."
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    # El árbol de trabajo tal cual (con lo que esté sin commit), sin lo que git ignora.
    (cd "$SERVER_REPO" && git ls-files -z | grep -zv '^remotion/' | COPYFILE_DISABLE=1 tar --null -T - -czf "$TMP/servidor.tgz")
    # MediaMTX del pod = el del socio, pero publicando desde internet con clave y leyendo
    # solo desde el propio pod.
    /usr/bin/python3 - "$SERVER_REPO/tools/mediamtx-ingest.yml" "$TMP/mediamtx.yml" "$RTMP_PASS" <<'PY'
import sys
from pathlib import Path
source, target, password = sys.argv[1:4]
text = Path(source).read_text(encoding="utf-8")
auth = text[text.index("authInternalUsers:"):text.index("paths:")]
text = text.replace(auth, f"""authInternalUsers:
  - user: rig
    pass: {password}
    ips: []
    permissions:
      - action: publish
  - user: any
    ips: ['127.0.0.0/8']
    permissions:
      - action: publish
      - action: read
""")
Path(target).write_text(text, encoding="utf-8")
PY
    printf 'panel:%s\n' "$(openssl passwd -apr1 "$PANEL_PASS")" > "$TMP/panel.htpasswd"

    pod_ssh 'mkdir -p /root/servidor/models/onnx /root/football-ai'
    DEST="root@$(field ip)"
    pod_scp "$TMP/servidor.tgz" "$DEST:/root/servidor.tgz"
    pod_scp "$TMP/mediamtx.yml" "$TMP/panel.htpasswd" "$REPO/tools/pod/servicios.sh" \
      "$REPO/tools/pod/nginx-panel.conf" "$DEST:/root/football-ai/"
    # El modelo pesa 120 MB y por una WiFi corriente tarda minutos: si el pod ya lo tiene
    # (mismo tamaño), no se vuelve a subir.
    if [ -f "$MODEL" ]; then
      REMOTE_SIZE="$(pod_ssh 'stat -c %s /root/servidor/models/onnx/rfdetr-small.onnx 2>/dev/null || echo 0')"
      [ "$REMOTE_SIZE" = "$(stat -f %z "$MODEL")" ] || pod_scp "$MODEL" "$DEST:/root/servidor/models/onnx/"
    fi
    [ -f "$RIG_JSON" ] && pod_scp "$RIG_JSON" "$DEST:/root/football-ai/soporte.json"

    # Las claves de las plataformas viajan por la sesión SSH a un fichero del pod que solo
    # lee root; el pod se borra entero al terminar.
    RELE=""
    for var in FBAI_YOUTUBE_KEY FBAI_FACEBOOK_KEY FBAI_TIKTOK_URL FBAI_TIKTOK_KEY; do
      [ -n "${!var:-}" ] && RELE="$RELE$var=${!var}"$'\n'
    done
    if [ -n "$RELE" ]; then
      printf '%s' "$RELE" | pod_ssh 'umask 077; cat > /root/football-ai/rele.env'
    else
      pod_ssh 'rm -f /root/football-ai/rele.env'
    fi

    echo "Instalando en el pod (unos minutos la primera vez)..."
    pod_ssh 'set -e
      cd /root/servidor && tar xzf ../servidor.tgz 2>/dev/null
      uv sync --group gpu --locked > /root/uv.log 2>&1 || { tail -5 /root/uv.log; exit 1; }
      cd /root/football-ai && chmod +x servicios.sh
      if [ ! -x mediamtx ]; then
        V=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | grep -o "\"tag_name\": *\"[^\"]*\"" | cut -d\" -f4)
        curl -sL "https://github.com/bluenviron/mediamtx/releases/download/$V/mediamtx_${V}_linux_amd64.tar.gz" | tar xz mediamtx
      fi
      command -v nginx >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq nginx-light; } >/dev/null 2>&1
      command -v ffmpeg >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq ffmpeg; } >/dev/null 2>&1
      FOOTBALL_CAMERA_URL="rtmp://rig:'"$RTMP_PASS"'@'"$(field ip)"':'"$(field rtmp_port)"'" ./servicios.sh start'

    echo "Esperando al panel..."
    for _ in $(seq 1 40); do
      code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "panel:$PANEL_PASS" "http://$(field ip):$(field panel_port)/" || true)"
      [ "$code" = "200" ] && break
      sleep 3
    done
    [ "${code:-}" = "200" ] && echo "Panel respondiendo." || echo "aviso: el panel aún no responde; mira tools/pod.sh status"
    info
    ;;
  info)
    pod_exists || { echo "no hay pod (tools/pod.sh up)"; exit 1; }
    info
    ;;
  status)
    pod_exists || { echo "no hay pod (tools/pod.sh up)"; exit 0; }
    runpodctl pod get "$(field id)" | /usr/bin/python3 -c "
import json, sys
pod = json.load(sys.stdin)
print(f\"  pod {pod['id']}: {pod.get('desiredStatus')} · \${pod.get('costPerHr')}/h · encendido hace {pod.get('uptimeSeconds', 0) // 60} min\")"
    pod_ssh '/root/football-ai/servicios.sh status' || echo "  (no contesta por SSH)"
    ;;
  ssh)
    pod_exists || { echo "no hay pod (tools/pod.sh up)"; exit 1; }
    shift; pod_ssh "$@"
    ;;
  down)
    pod_exists || { echo "no hay pod que borrar"; rm -f "$STATE"; exit 0; }
    echo "Se va a BORRAR el pod $(field id). No guarda nada: no se pierde más que la instalación."
    read -r -p "Escribe «borrar» para confirmar: " answer
    [ "$answer" = "borrar" ] || { echo "cancelado"; exit 1; }
    runpodctl pod delete "$(field id)" && rm -f "$STATE" && echo "Pod borrado: ya no cobra."
    ;;
  *)
    echo "uso: tools/pod.sh up | status | info | ssh | down"; exit 1
    ;;
esac
