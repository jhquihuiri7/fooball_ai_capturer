---
name: feedback-workflow-alexander
description: "Cómo quiere trabajar Alexander en este repo (17 Sep 2026): un milestone cada vez, él prueba en el iPhone, commit solo cuando confirma, respuestas cortas."
metadata:
  node_type: memory
  type: feedback
---

# Cómo trabaja Alexander aquí

- **Un milestone cada vez, probable en el iPhone.** Se entrega instalado en su móvil con
  una lista corta de qué mirar. Él prueba y dice si vale.
- **Commit solo cuando él confirma.** Si no vale, no se commitea; se corrige y se vuelve
  a instalar. Cuando pide "un commit con lo que tenemos", se hace y se le da el hash.
- **Menos texto.** Se quejó de una respuesta larga ("no entendí nada"). Ir al grano:
  qué pasa, qué mirar, una pregunta si hace falta. Sin listas largas de causas.
- Pega los logs de `flutter run`. Los `FigCaptureSourceRemote err=-17281`,
  `FigApplicationStateMonitor err=-19431` y `AppleProResHW` son ruido; un
  `NSInternalInconsistencyException` es un crash real.
- Pregunta dónde están las grabaciones: **Archivos → En mi iPhone → Football Ai
  Capture**, o Finder → iPhone → Archivos. No van a Fotos, a propósito.
- Quiere ver la cámara en pantalla y saber sin duda si está grabando y si se envía algo.
- Pidió opciones de grabación para el usuario: **no**, los ajustes son fijos por el ADR
  0012. Se le explicó y lo aceptó.
- Esta carpeta `memory/` se lee solo cuando él dice "revisa la memoria".

## Añadido por la tarde (17 Sep 2026): lo que NO hacer

Perdió la paciencia, y con razón: en el paso 3 le pedí cuatro veces "abre, pulsa,
dime qué sale", y teclear la IP del Mac en el móvil. Cita: *"no me tengas a mí haciendo
pruebitas para ver si vale; dame a mí a probar cuando tengas algo conciso"*.

- **Diagnosticar desde el Mac todo lo que se pueda** antes de involucrarle: probar el
  servidor con `srt-live-transmit` + `ingest_probe.py send`, mirar logs, copiar archivos
  del móvil con `devicectl device copy from`, dejar un vigilante que detecte su prueba.
- **Una sola prueba, de una acción**, cuando todo lo demás esté verificado. Sin IPs: el
  servidor se descubre por Bonjour y lo guardado persiste.
- Si necesito sus logs, que sea una vez, con la app ya con registro suficiente.
- Los permisos (cámara, red local) se piden al arrancar, no en mitad de la emisión.

