// Los picos del heatmap (IOS-23): la versión de cada ciclo, que recorta la ventana y solo
// ordena los mejores candidatos, contra la versión directa en mapas al azar con mesetas,
// empates y bordes; y el umbral en float32 como numpy. Los dorados de postprocess.json
// están en PostprocessTests.

import Foundation
import RigCore
import XCTest

final class HeatmapPeaksTests: XCTestCase {
    /// heatmap_peaks tal cual: la ventana entera con el borde replicado, todos los
    /// candidatos ordenados y la meseta.
    private func directa(_ heatmap: [[[Float]]], k: Int, threshold: Double, kernel: Int) -> [Postprocess.Peak] {
        let r = kernel / 2
        var candidatos: [Postprocess.Peak] = []
        for (c, mapa) in heatmap.enumerated() {
            let (h, w) = (mapa.count, mapa[0].count)
            for y in 0..<h {
                for x in 0..<w where mapa[y][x] > Float(threshold) {
                    var maximo = -Float.infinity
                    for dy in -r...r {
                        for dx in -r...r { maximo = max(maximo, mapa[min(max(y + dy, 0), h - 1)][min(max(x + dx, 0), w - 1)]) }
                    }
                    if mapa[y][x] >= maximo { candidatos.append(.init(klass: c, row: y, col: x, score: mapa[y][x])) }
                }
            }
        }
        candidatos.sort { ($0.score, -$0.klass, -$0.row, -$0.col) > ($1.score, -$1.klass, -$1.row, -$1.col) }
        var elegidos: [Postprocess.Peak] = []
        for p in candidatos where elegidos.count < k {
            if !elegidos.contains(where: { $0.klass == p.klass && abs($0.row - p.row) < kernel && abs($0.col - p.col) < kernel }) {
                elegidos.append(p)
            }
        }
        return elegidos
    }

    private struct Semilla {
        var estado: UInt64
        mutating func next(_ n: Int) -> Int {
            estado = estado &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((estado >> 33) % UInt64(n))
        }
    }

    func testCoincideConLaVersionDirecta() {
        // Pocos niveles para que haya mesetas y empates; Float(0.3) cae justo en el umbral.
        let niveles: [Float] = [0, 0.1, 0.25, Float(0.3), Float(0.3).nextUp, 0.5, 0.5, 0.9, 1]
        var s = Semilla(estado: 2026)
        var conTope = 0
        for caso in 0..<300 {
            let grande = caso >= 270
            let (cc, hh, ww) = (1 + s.next(3), 1 + s.next(grande ? 30 : 12), 1 + s.next(grande ? 40 : 12))
            // Los grandes, continuos: los mejores picos quedan repartidos por el mapa y no
            // al principio del recorrido, que es lo que pone a prueba ordenar solo los mejores.
            let valor = { grande ? Float(s.next(1 << 20)) / Float(1 << 20) : niveles[s.next(niveles.count)] }
            let mapa = (0..<cc).map { _ in (0..<hh).map { _ in (0..<ww).map { _ in valor() } } }
            let k = [1, 2, 5, 64, 1000][s.next(5)]
            let kernel = [3, 3, 5][s.next(3)]
            let umbral = [0.25, 0.3][s.next(2)]
            let rapida = Postprocess.heatmapPeaks(mapa, k: k, threshold: umbral, kernel: kernel)
            XCTAssertEqual(rapida, directa(mapa, k: k, threshold: umbral, kernel: kernel), "caso \(caso)")
            if rapida.count == k, cc * hh * ww > k * (2 * kernel - 1) * (2 * kernel - 1) { conTope += 1 }
        }
        XCTAssertGreaterThan(conTope, 10, "casos con más candidatos que los que se ordenan")
    }

    /// numpy compara `heatmap > 0.3` en float32 (NEP 50): Float(0.3) es 0,30000001 y NO
    /// pasa; en Double pasaría.
    func testElUmbralEsEstrictoYEnFloat32() {
        XCTAssertGreaterThan(Double(Float(0.3)), 0.3)
        let mapa: [[[Float]]] = [[[0, 0, 0], [0, Float(0.3), 0], [0, 0, 0]]]
        XCTAssertEqual(Postprocess.heatmapPeaks(mapa, k: 4, threshold: 0.3), [])
        let encima: [[[Float]]] = [[[0, 0, 0], [0, Float(0.3).nextUp, 0], [0, 0, 0]]]
        XCTAssertEqual(Postprocess.heatmapPeaks(encima, k: 4, threshold: 0.3).map(\.row), [1])
    }

    func testElBordeCompiteSoloConLoQueExiste() {
        var mapa: [[[Float]]] = [Array(repeating: Array(repeating: 0, count: 5), count: 4)]
        (mapa[0][0][0], mapa[0][0][1], mapa[0][3][4]) = (0.9, 0.5, 0.8)
        let picos = Postprocess.heatmapPeaks(mapa, k: 4, threshold: 0.3)
        XCTAssertEqual(picos.map { [$0.row, $0.col] }, [[0, 0], [3, 4]], "las dos esquinas")
    }
}
