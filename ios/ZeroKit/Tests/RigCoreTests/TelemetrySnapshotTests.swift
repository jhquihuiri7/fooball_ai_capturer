import XCTest

@testable import RigCore

final class TelemetrySnapshotTests: XCTestCase {
    private func makeSnapshot() -> TelemetrySnapshot {
        TelemetrySnapshot(
            rigMs: 1_234_567,
            fps: 30.0,
            didDrop: 0,
            queueDrops: ["telemetry": 1],
            stages: ["infer": StageTelemetry(p50Ms: 12, p90Ms: 16, p99Ms: 22, hz: 7.5)],
            inferMsByModel: ["dfine-n-band": 11.5],
            thermalState: "fair",
            systemPressure: "nominal",
            ladderLevel: 0,
            batteryLevel: 0.82,
            charging: true,
            availableMemoryBytes: 1_200_000_000,
            linkRttMs: 4.2,
            linkLossPercent: 0.0,
            programBitrateBps: 6_000_000
        )
    }

    func testEncodingIsStableAndSnakeCased() throws {
        // El contrato de REF-45: claves fijas y ordenadas. Si esta cadena cambia,
        // cambia el contrato, y eso se decide allí, no aquí por accidente.
        let linea = try String(data: makeSnapshot().jsonLine(), encoding: .utf8)

        let esperado = """
        {"available_memory_bytes":1200000000,"battery_level":0.82,"charging":true,\
        "did_drop":0,"fps":30,"infer_ms_by_model":{"dfine-n-band":11.5},\
        "ladder_level":0,"link_loss_percent":0,"link_rtt_ms":4.2,\
        "program_bitrate_bps":6000000,"queue_drops":{"telemetry":1},"rig_ms":1234567,\
        "stages":{"infer":{"hz":7.5,"p50_ms":12,"p90_ms":16,"p99_ms":22}},\
        "system_pressure":"nominal","thermal_state":"fair"}
        """
        XCTAssertEqual(linea, esperado)
    }

    func testRoundTripsThroughCodable() throws {
        let original = makeSnapshot()
        let data = try original.jsonLine()
        let vuelta = try JSONDecoder().decode(TelemetrySnapshot.self, from: data)

        XCTAssertEqual(vuelta, original)
    }

    func testStageTelemetryComesFromAHistogram() {
        var histograma = LatencyHistogram()
        for _ in 0..<100 { histograma.record(ms: 10) }

        let etapa = StageTelemetry(histogram: histograma, hz: 30)

        XCTAssertEqual(etapa.p50Ms, 12)
        XCTAssertEqual(etapa.hz, 30)
    }
}
