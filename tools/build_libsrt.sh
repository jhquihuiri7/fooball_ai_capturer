#!/usr/bin/env bash
# Compila libsrt con mbedTLS en un xcframework propio (IOS-55; decisión 1 del plan de dos
# móviles): ios/ZeroKit/Frameworks/CSrt.xcframework, el que enlaza RigNet.
#
#   tools/build_libsrt.sh            # baja, comprueba, compila y deja el xcframework
#   LIBSRT_WORK=/ruta tools/build_libsrt.sh   # reutiliza una carpeta de trabajo
#
# Las versiones y sus SHA-256 van fijadas aquí: el binario que se commitea sale de estas
# fuentes y de nada más, y sale igual byte a byte con el mismo Xcode. mbedTLS va en la rama
# 3.6 LTS: el haicrypt de libsrt 1.5 está escrito contra su API clásica de cifrado, que la 4
# cambia por PSA. Solo entra libmbedcrypto, lo que necesita la passphrase (AES, PBKDF2 y el
# generador aleatorio).
#
# Rodajas: iPhone, simulador (arm64) y el Mac (arm64, para `swift test`). El módulo de
# Clang se llama CSrt, la librería libcsrt.a y la API csrt_*: nada choca con el libsrt de
# SRTHaishinKit mientras convivan en el Runner (hasta IOS-91).
#
# Necesita Xcode y cmake; si no hay cmake en el PATH lo trae uvx, sin instalar nada.
set -euo pipefail

SRT_VERSION=1.5.7
SRT_SHA256=017cd1e437ef2073a4dd10ddf7b55e86bc3d6ebac0393d13bd22f6a57055d32b
SRT_URL="https://github.com/Haivision/srt/archive/refs/tags/v${SRT_VERSION}.tar.gz"
MBEDTLS_VERSION=3.6.7
MBEDTLS_SHA256=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
MBEDTLS_URL="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/mbedtls-${MBEDTLS_VERSION}.tar.bz2"
# El mismo mínimo que ios/ZeroKit/Package.swift.
DEPLOYMENT_TARGET=26.0

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="$RAIZ/ios/ZeroKit/Frameworks"
if [ -n "${LIBSRT_WORK:-}" ]; then
  WORK="$LIBSRT_WORK"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
fi
echo "carpeta de trabajo: $WORK"

if command -v cmake >/dev/null; then
  CMAKE=(cmake)
else
  CMAKE=(uvx --from 'cmake>=3.28,<4' cmake)
fi

# Cada descarga en su carpeta: son datos de fuera hasta que cuadra el SHA.
bajar() {  # url sha256 fichero
  local dir="$WORK/descargas/$3"
  mkdir -p "$dir"
  [ -f "$dir/$3" ] || curl -fsSL "$1" -o "$dir/$3"
  local visto
  visto=$(shasum -a 256 "$dir/$3" | cut -d' ' -f1)
  if [ "$visto" != "$2" ]; then
    rm -f "$dir/$3"; echo "SHA-256 de $3 no cuadra: $visto" >&2; exit 1
  fi
  echo "$dir/$3"
}

srt_tar=$(bajar "$SRT_URL" "$SRT_SHA256" "srt-${SRT_VERSION}.tar.gz")
mbed_tar=$(bajar "$MBEDTLS_URL" "$MBEDTLS_SHA256" "mbedtls-${MBEDTLS_VERSION}.tar.bz2")
rm -rf "$WORK/src" && mkdir -p "$WORK/src"
tar -xzf "$srt_tar" -C "$WORK/src"
tar -xjf "$mbed_tar" -C "$WORK/src"
SRT_SRC="$WORK/src/srt-${SRT_VERSION}"
# cmake escribe /tmp y /var donde el disco dice /private/tmp y /private/var: las tres formas.
MAPA_RUTAS=""
for raiz in "$WORK" "$(cd "$WORK" && pwd -P)" "${WORK#/private}"; do
  MAPA_RUTAS+=" -ffile-prefix-map=$raiz/src/="
done
MBED_SRC="$WORK/src/mbedtls-${MBEDTLS_VERSION}"

compilar() {  # rodaja sysroot sistema triple
  local rodaja=$1 sysroot=$2 sistema=$3 triple=$4
  local pre="$WORK/prefijo/$rodaja"
  local comunes=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_SYSROOT="$sysroot"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_INSTALL_PREFIX="$pre"
    # Sin símbolos comunes, que el prelinkado no puede ocultar, y sin la ruta de la carpeta
    # de trabajo en los __FILE__ del binario: así sale igual se compile donde se compile.
    -DCMAKE_C_FLAGS="-fno-common $MAPA_RUTAS"
    -DCMAKE_CXX_FLAGS="$MAPA_RUTAS"
    -Wno-dev -Wno-deprecated
  )
  [ "$sistema" = iOS ] && comunes+=(-DCMAKE_SYSTEM_NAME=iOS)
  echo "== mbedTLS $MBEDTLS_VERSION · $rodaja"
  "${CMAKE[@]}" -S "$MBED_SRC" -B "$WORK/obj/mbedtls-$rodaja" "${comunes[@]}" \
    -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON >/dev/null
  "${CMAKE[@]}" --build "$WORK/obj/mbedtls-$rodaja" --target install -j "$(sysctl -n hw.ncpu)" >/dev/null
  echo "== libsrt $SRT_VERSION · $rodaja"
  "${CMAKE[@]}" -S "$SRT_SRC" -B "$WORK/obj/srt-$rodaja" "${comunes[@]}" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF -DENABLE_BONDING=OFF \
    -DENABLE_CXX_DEPS=OFF -DENABLE_STDCXX_SYNC=ON -DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=mbedtls \
    -DSSL_INCLUDE_DIRS="$pre/include" -DSSL_LIBRARY_DIRS="$pre/lib" \
    -DSSL_LIBRARIES="$pre/lib/libmbedcrypto.a" >/dev/null
  "${CMAKE[@]}" --build "$WORK/obj/srt-$rodaja" --target install -j "$(sysctl -n hw.ncpu)" >/dev/null

  # Un solo objeto prelinkado por rodaja (libsrt + libmbedcrypto) que exporta SOLO la API
  # C de libsrt, renombrada a csrt_*; el C++ de libsrt, haicrypt y mbedTLS quedan ocultos.
  # El libsrt de SRTHaishinKit exporta los mismos nombres sin prefijo: así los dos caben en
  # el Runner sin símbolos duplicados y RigNet usa siempre este (hasta IOS-91).
  local out="$WORK/rodajas/$rodaja"
  rm -rf "$out" && mkdir -p "$out/Headers/CSrt"
  nm -gU -j "$pre/lib/libsrt.a" 2>/dev/null | grep -E '^_srt_' | sort -u >"$out/api.txt"
  awk '{print $1" _c"substr($1, 2)}' "$out/api.txt" >"$out/alias.txt"
  awk '{print "_c"substr($1, 2)}' "$out/api.txt" >"$out/exports.txt"
  local forzar=()
  while read -r simbolo; do forzar+=("-Wl,-u,$simbolo"); done <"$out/api.txt"
  xcrun -sdk "$sysroot" clang -target "$triple" -r -nostdlib "${forzar[@]}" \
    "$pre/lib/libsrt.a" "$pre/lib/libmbedcrypto.a" \
    -Wl,-alias_list,"$out/alias.txt" -Wl,-exported_symbols_list,"$out/exports.txt" -o "$out/csrt.o"
  local fuera
  fuera=$(nm -gU -j "$out/csrt.o" | grep -v '^_csrt_' || true)
  [ -z "$fuera" ] || { echo "csrt.o exporta más que la API: $fuera" >&2; exit 1; }
  libtool -static -D -o "$out/libcsrt.a" "$out/csrt.o"

  # Las cabeceras C de libsrt (udt.h es C++ y se queda fuera) y csrt.h, que les pone el
  # prefijo: desde Swift se llama csrt_startup(), csrt_connect()…
  for h in srt.h version.h platform_sys.h logging_api.h access_control.h; do
    cp "$pre/include/srt/$h" "$out/Headers/CSrt/"
  done
  {
    echo "// Generado por tools/build_libsrt.sh: la API C de libsrt $SRT_VERSION con el prefijo"
    echo "// csrt_, el único nombre que exporta libcsrt.a (IOS-55)."
    sed -E 's/^_(.*)$/#define \1 c\1/' "$out/api.txt"
    echo '#include "srt.h"'
    echo '#include "access_control.h"'
  } >"$out/Headers/CSrt/csrt.h"
  cat >"$out/Headers/CSrt/module.modulemap" <<'MAPA'
module CSrt {
    header "csrt.h"
    link "c++"
    export *
}
MAPA
}

compilar ios-arm64 iphoneos iOS "arm64-apple-ios$DEPLOYMENT_TARGET"
compilar ios-arm64-simulator iphonesimulator iOS "arm64-apple-ios$DEPLOYMENT_TARGET-simulator"
compilar macos-arm64 macosx Darwin "arm64-apple-macos$DEPLOYMENT_TARGET"

mkdir -p "$DESTINO"
rm -rf "$DESTINO/CSrt.xcframework"
args=()
for rodaja in ios-arm64 ios-arm64-simulator macos-arm64; do
  args+=(-library "$WORK/rodajas/$rodaja/libcsrt.a" -headers "$WORK/rodajas/$rodaja/Headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$DESTINO/CSrt.xcframework" >/dev/null

# Las licencias viajan con el binario: MPL-2.0 pide decir dónde está la fuente (arriba,
# con su SHA) y Apache-2.0, llevar su texto.
mkdir -p "$DESTINO/licenses"
cp "$SRT_SRC/LICENSE" "$DESTINO/licenses/libsrt-${SRT_VERSION}-MPL-2.0.txt"
cp "$MBED_SRC/LICENSE" "$DESTINO/licenses/mbedtls-${MBEDTLS_VERSION}-LICENSE.txt"
echo "listo: $DESTINO/CSrt.xcframework (libsrt $SRT_VERSION, mbedTLS $MBEDTLS_VERSION)"
