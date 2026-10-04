# BenchResources (SPK-50)

Aquí deja sus recursos quien lanza el banco de modelos (`ModelBenchTests`):

- `bench.json` — los modelos a medir: `{"models": [{"name", "package",
  "predictions", "warmup", "compute_units", "golden"}]}`.
- `<nombre>.mlpackage/` — los paquetes exportados por el repo de entrenamiento
  (ML-09/ML-16).
- `golden/<modelo>-<versión>/` — los bundles dorados de ML-12.

En git solo vive este README: los paquetes pesan y caducan con cada export.
Sin `bench.json`, el banco se salta solo (Mac, CI).
