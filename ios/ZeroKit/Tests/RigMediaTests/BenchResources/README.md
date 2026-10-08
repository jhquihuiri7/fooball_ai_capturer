# BenchResources (SPK-50)

Aquí deja sus recursos quien lanza el banco de modelos (`ModelBenchTests`):

- `bench.json` — los modelos a medir: `{"models": [{"name", "package",
  "predictions", "warmup", "compute_units", "golden"}]}`. Con `"function"`, una
  función de un paquete multifunción (SPK-52); con `"sequence": "golden/<bundle>"`,
  un modo paso con estado que recorre su secuencia dorada (SPK-53, SequenceBench).
  Otro fichero de modelos se elige con `MODEL_BENCH_SPEC=<fichero>`, en el Mac y en
  el iPhone (`tools/spk53_bench.sh` deja los suyos).
- `<nombre>.mlpackage/` — los paquetes exportados por el repo de entrenamiento
  (ML-09/ML-16).
- `golden/<modelo>-<versión>/` — los bundles dorados de ML-12.

En git solo vive este README: los paquetes pesan y caducan con cada export.
Sin `bench.json`, el banco se salta solo (Mac, CI).
