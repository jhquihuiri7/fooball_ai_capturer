# La primera prueba en la cancha, sin internet

Los dos iPhone en el trípode, enlazados entre ellos por Wi-Fi Aware (sin router ni datos). El
17 compone el programa en directo y lo graba en el propio móvil; cada uno graba además su 4K.
La Mac va para calibrar, para el plan B y para recoger al final.

## Qué está probado y qué no (2026-10-15)

| | Estado |
|---|---|
| EMITIR de producción, 60 min por Aware y sin destino, con la escalera térmica | ✅ en los dos iPhone, con el botón pulsado por el modo automático. Vídeo completo (1:00:00), 0 desgarros, latencia fija |
| El plan B desde la Mac (lanzar y soltar los cables) | ✅ en los dos iPhone, tras el arreglo del enlace |
| Aware tras cerrar Zero con el enlace vivo (546917d) | ✅ una vez: enlazó a los 90 s; antes, 5 min sin enlazar. Lo normal, de 10 s a 2 min |
| La 4K de los dos en EMITIR («Guardar vídeo», f2f2c21) | ✅ el 17, con el modo automático. El 16 Pro no la grabó: le quedan 10 GB y la reserva no le deja. Borra las pruebas viejas antes |
| Calibrar con `calibrar_cancha.sh` | ✅ la mecánica en los dos iPhone (en casa dice «NO CALIBRA», como debe dentro de un cuarto). ❌ nunca calibró en una cancha |
| **Pulsar EMITIR con el dedo**, la pantalla de lado, el botón lateral y otra app a mitad | ❌ sin probar en los iPhone |
| **Aware en modo avión** (con la Wi-Fi encendida) | ❌ sin probar |
| El director con jugadores de verdad | ❌ en casa se quedaba fijo en un rincón del cuarto |
| 90-120 min al sol | ❌ el calor solo se midió a la sombra; la escalera baja la IA a 5 Hz en `serious` |
| **«Una cámara (sin pareja)»**: emitir con un solo móvil, sin enlazar (2026-10-15) | ❌ sin probar en el iPhone: hecho en código y con pruebas. Pruébalo antes con `tools/emitir_auto.sh <secreto> 300 --link single` (un solo iPhone por cable) |

## Lo primero al abrir Zero: el tipo de evento (2026-10-19)

La app ya no abre en la pantalla de lado: pregunta **«¿Qué vas a transmitir?»**.

- **Fútbol**: la pantalla de siempre (lado, enlace, VPS…). Todo lo de esta guía.
- **Espectáculo** (festivales, presentaciones): un solo móvil. Elige la calidad, escanea el QR
  Soporte y «Abrir cámara». Desde el mando web (QR «Mando»), la tarjeta **Rótulos**: guarda
  cada número con su título y su subtítulo («Presentación artística: Los Ángeles del Cielo» /
  «Cantado por …») y sácalo 10 s o «Fijo». EN VIVO sale solo arriba a la izquierda.
- **Vóleibol**: un solo móvil y la cámara tal cual, sin gráficos por ahora.

**Una noche con varios partidos** (fútbol): antes del primero, carga en el mando web la
tarjeta **Jornada** con todos los partidos y sus escudos. Al empezar cada uno, «Partido de la
jornada» → **Empezar** (pone los nombres, los escudos y el reloj a cero, sin escribir nada).
Al acabar, **Finalizar partido**: el marcador queda guardado. Al final de la noche, en Al aire,
**Resultados**. El gol sale solo en pantalla con cada «+ Gol»; si fue un error, «− 1» lo quita.
Para una premiación, en Al aire, **Ocultar marcador y reloj**.

**Anuncios de la franja**: la franja pasó de 108 a 132 px. Los paquetes de anuncios hechos
antes no cargan: hay que volver a rendrizarlos con Remotion y subirlos al VPS.

## La víspera, en casa

1. En la Mac, en la rama `migracion/dos-moviles`:
   ```bash
   cd ~/Trabajacion/fooball_ai_capturer && git pull --ff-only
   tools/plan_b_cancha.sh preparar        # las tres apps, compiladas en casa (en la cancha no se compila)
   tools/plan_b_cancha.sh volver          # deja la app de EMITIR en los dos
   ```
2. **Sitio en los móviles:** cada uno necesita ~50 GB libres para 2 h con la 4K. Mira
   `tools/limpiar_moviles.sh` y, si hace falta, `tools/limpiar_moviles.sh --borrar-pruebas`,
   que borra las grabaciones de prueba de antes de hoy. En la app, «Disco libre».
3. **Sitio en la Mac:** un partido son ~5 GB de programa y ~40 GB de 4K por móvil. Lleva un
   disco externo.
4. Cargar al 100 % los dos iPhone, las dos baterías externas y la Mac. Cables USB-C de los dos.
5. El secreto del soporte ya está en los dos iPhone y en `~/.config/football-ai/secreto-soporte`.

## En la cancha

1. **Montar** el trípode en alto, en la mitad del campo, con las dos cámaras mirando a la cancha.
   A la sombra si se puede, los móviles sin funda y con la batería externa puesta.
2. **En los dos:** «No molestar» y el bloqueo automático en «Nunca». Prueba primero el **modo
   avión con la Wi-Fi encendida**; si en el paso 5 no enlazan en 2 min, quita el modo avión y
   apaga los datos móviles.
3. **Calibrar** (los dos por cable a la Mac, quietos):
   ```bash
   tools/calibrar_cancha.sh ~/.config/football-ai/secreto-soporte
   ```
   - «✅ CALIBRA»: instala la calibración nueva en los dos y la comprueba.
   - «❌ NO CALIBRA»: apunta a algo con textura en el centro (gradas, vallas, árboles) a más de
     20 m y repite. Si los montaste igual que en casa, puedes seguir con la de casa.
4. Quita los cables si quieres. **Abre Zero desde el icono** en los dos: el 17 **IZQUIERDA** y
   «Este móvil dirige»; el 16 Pro **DERECHA**. «Enlace y emisión» → **Aware** en los dos. En el
   17, la tarjeta VPS vacía («Desemparejar» si había algo).
5. **«Abrir cámara»** en los dos y espera a **LISTA** (Enlace conectado, Reloj y Fase). Puede
   tardar hasta 2-3 min: no toques nada mientras, se reintenta solo.
6. En el 17: **«Guardar vídeo»** encendido (la 4K de los dos) y **EMITIR**. El 16 Pro pasa solo
   a EMITIENDO. La tarjeta Programa del 17 dice «SIN DESTINO»: es lo esperado, el programa se
   graba en el móvil.
7. **Durante el partido** no toques los móviles. Si quieres mirar, la tarjeta Programa del 17:
   ~30 fps, Parte en verde y Escalera. En el descanso, «Batería» y «Disco libre» de los dos.
8. **Al acabar:** PARAR en el 17 y comprueba que el 16 Pro también paró.
9. **Recoger** (en casa o allí, por cable):
   ```bash
   SALIDA=/Volumes/<disco>/partido-$(date +%Y%m%d) tools/recoger_partido.sh
   ```
   Al final da un ✅ o ❌ por cada cosa. Pásame la carpeta.

## Con internet (el día del Starlink): el móvil que emite, solo por esa Wi-Fi

Medido el 2026-10-15 emitiendo al VPS desde casa: el iPhone saltaba entre la Wi-Fi floja y
los datos móviles (la «Asistencia Wi-Fi» de iOS), cada salto cortaba la conexión y YouTube
daba el directo por terminado; por datos móviles llegaba del 2 al 43 % del vídeo. Desde la
Wi-Fi cerca del router, el 100 % a 5 Mbit/s.

- En el móvil que emite: **datos móviles apagados** (o al menos Ajustes → Datos móviles →
  «Asistencia Wi-Fi» apagada) y conectado a la Wi-Fi del Starlink, cerca del router.
- Antes del partido, desde la Mac en esa misma Wi-Fi: `./deploy/vps-prueba.sh 120` en
  football-ai (mide la subida real al VPS) y `./deploy/vps-estado.sh`.
- Mientras emite, **no salir de Zero** en ese móvil: la cámara no corre en segundo plano
  y iOS puede matar la app al volver (visto el 2026-10-15 a las 18:32).

## Si algo falla

| Qué pasa | Qué hacer |
|---|---|
| No enlazan y quieres saber por qué | La fila Enlace de cada móvil dice la frase («publicando; no ha llegado nadie en 90 s (3 citas, 2 rehechas)», «no ve al otro…», «ve al otro pero no conecta…»). Cada móvil lo deja también en `Documents/bench/link-diag-*.json`, que recogen los guiones y enseña el veredicto. El que publica rehace su cita cada 30 s y el que busca la suya cada 20 s: no hace falta tocar nada en los primeros 2 min |
| El 16 Pro no enlaza en 3 min | Cierra Zero en los dos, espera 1 min y ábrela otra vez (lado, Aware, «Abrir cámara»). Si sigue sin enlazar, quita el modo avión (datos móviles apagados) y repite. Si sigue sin enlazar, la fila siguiente |
| **No hay forma de enlazar** (o solo hay un iPhone) | **«Una cámara (sin pareja)» en el 17.** Si estaba emitiendo, PARAR; vuelve atrás a la pantalla de lado: **IZQUIERDA**, «Enlace y emisión» → **«Una cámara (sin pareja)»** (la píldora ancha, debajo de Pod/Wi-Fi/Aware/Cable), «Abrir cámara». Sale **LISTA** en segundos, sin enlace, sin reloj del otro y sin fase. «Guardar vídeo» si quieres su 4K y **EMITIR**. El 17 emite solo con todo: el director con su IA (recorre su lente y no encuadra nada fuera de ella), el gráfico, la franja con los anuncios y la copia del programa en el móvil (1080p). La tarjeta Programa dice «SIN DESTINO» sin QR Soporte, y la fila Parte, «sin pareja». El móvil va **en su sitio del soporte, girado como siempre**: el lado le dice a la app cómo va montado (IZQUIERDA, girado; DERECHA, derecho). Una lente ve ~100° de ancho y el soporte la abre ~40° hacia su lado: si puedes, gira el soporte para que apunte al centro de la cancha. Si solo queda el 16 Pro, lo mismo en él con **DERECHA** |
| Y además quieres la 4K del 16 Pro (último recurso) | Con el 17 en «Una cámara»: en el 16 Pro, cierra Zero, ábrela, enciende «Un solo móvil, sin reloj», «Abrir cámara» y GRABAR. Graba su 4K, que no parea con nada (sin reloj del soporte) |
| EMITIR no arranca o se queda raro | El plan B, por cable: `tools/plan_b_cancha.sh lanzar ~/.config/football-ai/secreto-soporte 7200`. Graba 2 h y se para solo; se pueden quitar los cables. Luego `tools/plan_b_cancha.sh volver` |
| Se cierra Zero en el 16 Pro | Ábrela y «Abrir cámara»: vuelve solo al programa. El 17 sigue mientras tanto con una lente |
| Se cierra Zero en el 17 | Lo grabado hasta ahí se puede leer. Ábrela, «Abrir cámara» y EMITIR otra vez |
| Temperatura «serious» | Es normal al sol: la IA baja a 5 Hz y el programa sigue. Sombra. En «critical» la IA se apaga y el programa sigue en plano abierto |
| Batería baja | La batería externa. A batería sola, el 16 Pro gasta ~20-33 % por hora |
