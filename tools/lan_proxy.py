#!/usr/bin/env python3
"""Abre el panel del servidor local a la red: reenvía un puerto de este Mac al panel.

El panel de `football-ai` escucha solo en 127.0.0.1 (no tiene contraseña). Esto lo deja
ver y operar desde otro equipo de la misma WiFi sin tocar ni reiniciar el panel:

    python3 tools/lan_proxy.py            # 0.0.0.0:8091 -> 127.0.0.1:8090

Quien entre puede mover el marcador y cortar la emisión: usarlo solo en redes de confianza
y cerrarlo (Ctrl+C) al terminar. La vista previa remota va por JPEG: la de WebRTC de
MediaMTX solo se sirve en local.
"""

import asyncio
import sys

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8091
TARGET = ("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 8090)
CHUNK_BYTES = 65536


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(CHUNK_BYTES):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(*TARGET)
    except OSError:
        writer.close()  # el panel está apagado
        return
    await asyncio.gather(pump(reader, upstream_writer), pump(upstream_reader, writer))


async def main() -> None:
    server = await asyncio.start_server(handle, "0.0.0.0", LISTEN_PORT)
    print(f"panel abierto a la red en el puerto {LISTEN_PORT} (Ctrl+C para cerrar)", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
