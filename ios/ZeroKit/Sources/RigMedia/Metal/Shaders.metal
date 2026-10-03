// Los kernels Metal de RigMedia (IOS-04).
//
// SwiftPM compila este fichero a default.metallib dentro de Bundle.module. Hoy solo
// vive el noop, que mantiene la cadena de carga en pie; los kernels de verdad llegan
// con el preproceso de la franja y el render repartido (IOS-20 en adelante).

#include <metal_stdlib>
using namespace metal;

kernel void rig_noop(uint2 gid [[thread_position_in_grid]]) {}
