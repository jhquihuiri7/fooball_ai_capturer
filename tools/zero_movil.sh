#!/bin/bash
# Lo común de los guiones de la cancha con los iPhone por cable (2026-10-14): ver si están,
# instalar, cerrar SOLO Zero, lanzar con un entorno, listar y copiar del contenedor.
# Se carga con `source tools/zero_movil.sh`; lo usan sesion_emitir.sh, recoger_partido.sh y
# plan_b_cancha.sh. tools/banco_dos_moviles.sh hace lo mismo por su cuenta (probado; no se
# toca).
#
# Variables que lee: APP (bundle id), RAIZ (la raíz del repo). XCRUN, para las pruebas con un
# devicectl falso (tools/test_guiones_cancha.sh); por defecto, xcrun.

XCRUN=${XCRUN:-xcrun}
ZM_LISTADO_INTENTOS=3
ZM_LISTADO_TIMEOUT_S=180   # s que puede tardar un listado, con miles de fotos de calibración
ZM_LISTADO_PAUSA_S=10      # s entre un intento y el siguiente

# Los dispositivos de $@ que devicectl ve conectados (por cable o por la red), uno por línea.
zm_conectados() {
  local f; f=$(mktemp)
  "$XCRUN" devicectl list devices --json-output "$f" >/dev/null 2>&1 || true
  python3 - "$f" "$@" <<'PY'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except (OSError, KeyError, ValueError):
    devs = []
conectados = {d.get("identifier") for d in devs
              if (d.get("connectionProperties") or {}).get("tunnelState") == "connected"}
for ident in sys.argv[2:]:
    if ident in conectados:
        print(ident)
PY
  rm -f "$f"
}

# Cierra el proceso de Zero, y solo ese (toda app de Flutter se llama Runner.app).
zm_mata() {  # $1 dispositivo
  local apps procs pid; apps=$(mktemp); procs=$(mktemp)
  "$XCRUN" devicectl device info apps --device "$1" --json-output "$apps" >/dev/null 2>&1 || true
  "$XCRUN" devicectl device info processes --device "$1" --json-output "$procs" >/dev/null 2>&1 || true
  for pid in $(python3 "$RAIZ/tools/procesos_zero.py" "$apps" "$procs" "$APP"); do
    "$XCRUN" devicectl device process terminate --device "$1" --pid "$pid" >/dev/null 2>&1 || true
  done
  rm -f "$apps" "$procs"
}

zm_instala() {  # $1 dispositivo, $2 Runner.app
  "$XCRUN" devicectl device install app --device "$1" "$2" 2>&1 | grep -c "App installed" >/dev/null
}

# Lanza Zero con el entorno de un fichero JSON (que no pasa por la pantalla).
zm_lanza() {  # $1 dispositivo, $2 fichero con el entorno en JSON
  "$XCRUN" devicectl device process launch --device "$1" --environment-variables "$(cat "$2")" "$APP" \
    >/dev/null 2>&1
}

# El listado del contenedor de Zero en $2. Reintenta: a veces sale vacío (iOS 27, 2026-10-14).
zm_lista() {  # $1 dispositivo, $2 fichero de salida
  local n=1
  while [ "$n" -le $ZM_LISTADO_INTENTOS ]; do
    "$XCRUN" devicectl device info files --device "$1" --domain-type appDataContainer --domain-identifier "$APP" \
      --timeout $ZM_LISTADO_TIMEOUT_S > "$2" 2> "$2.err" || true
    if grep -q 'Documents/' "$2"; then return 0; fi
    if [ "$n" -lt $ZM_LISTADO_INTENTOS ]; then sleep "${ZM_LISTADO_PAUSA_S_PRUEBA:-$ZM_LISTADO_PAUSA_S}"; fi
    n=$(( n + 1 ))
  done
  return 1
}

# Copia Documents/$3 a $2/$3; lo que falla, a $2/no-copiados.txt.
zm_copia() {  # $1 dispositivo, $2 carpeta del lado, $3 ruta relativa a Documents
  mkdir -p "$(dirname "$2/$3")"
  "$XCRUN" devicectl device copy from --device "$1" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "Documents/$3" --destination "$2/$3" >/dev/null 2>&1 && [ -e "$2/$3" ] && return 0
  echo "  NO se pudo copiar $3"
  echo "$3" >> "$2/no-copiados.txt"
  return 1
}

# El entorno de lanzamiento con el secreto del soporte (y lo que traiga $2 en JSON), en un
# fichero 600 que se devuelve por la salida. El secreto no sale por pantalla.
zm_entorno() {  # $1 fichero con el secreto, $2 JSON extra
  local f; f=$(mktemp); chmod 600 "$f"
  python3 - "$1" "$2" > "$f" <<'PY'
import json, sys
e = {"RIG_LINK_SECRET": open(sys.argv[1]).read().strip()}
e.update(json.loads(sys.argv[2]))
print(json.dumps(e))
PY
  echo "$f"
}
