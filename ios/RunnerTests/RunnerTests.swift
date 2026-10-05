import RigCore
import XCTest

@testable import Runner

/// Robustez de campo (TASK A7 y A9): lo que no puede cambiar sin que se note en la cancha.
final class FieldRobustnessTests: XCTestCase {
    func testSegmentNamesKeepTheSideAndNumberTheCuts() {
        XCTAssertEqual(CaptureEngine.segmentName(role: .left, epochSeconds: 1_700_000_000, segment: 1), "left-1700000000.mov")
        XCTAssertEqual(CaptureEngine.segmentName(role: .right, epochSeconds: 1_700_000_000, segment: 3), "right-1700000000-3.mov")
    }

    func testBitrateStepsDownWithHeatAndNeverToZero() {
        XCTAssertEqual(CaptureEngine.bitrateFraction(for: .nominal), 1.0)
        XCTAssertEqual(CaptureEngine.bitrateFraction(for: .fair), 1.0)
        XCTAssertLessThan(CaptureEngine.bitrateFraction(for: .serious), 1.0)
        XCTAssertLessThan(CaptureEngine.bitrateFraction(for: .critical), CaptureEngine.bitrateFraction(for: .serious))
        XCTAssertGreaterThan(CaptureEngine.bitrateFraction(for: .critical), 0.0)
    }
}

/// Lo que ata a RigLink con el enlace y con el contrato de pigeon.
final class RigLinkTests: XCTestCase {
    func testServiceTypeFitsMultipeerLimit() {
        // Multipeer exige de 1 a 15 caracteres en minúsculas, números y guiones.
        XCTAssertLessThanOrEqual(RigLink.serviceType.count, 15)
        XCTAssertNil(RigLink.serviceType.range(of: "[^a-z0-9-]", options: .regularExpression))
    }

    func testPigeonCommandsAndWireCatalogNeverDiverge() {
        // El catálogo del cable (RigCore) y el enum de pigeon tienen que ser el mismo
        // conjunto: si pigeon gana un caso sin byte en el cable, este test lo dice
        // antes de que un «graba» se pierda en silencio.
        XCTAssertEqual(RigCommand.allCases.count, RigWireCommand.allCases.count)
        for command in RigCommand.allCases {
            XCTAssertNotNil(RigWireCommand(rawValue: UInt8(command.rawValue)), "sin byte: \(command)")
        }
        for wire in RigWireCommand.allCases {
            XCTAssertNotNil(RigCommand(rawValue: Int(wire.rawValue)), "sin caso pigeon: \(wire)")
        }
    }
}

final class AdaptiveBitRateTests: XCTestCase {
    func testBacksOffToWhatActuallyWentOutWithMargin() {
        // Codificando a 15 Mbit/s salieron 2: se baja a 1,6 (el 80 % de lo que cupo).
        XCTAssertEqual(AdaptiveBitRate.next(current: 15_000_000, measured: 2_000_000), 1_600_000)
    }

    func testNeverRaisesOnACongestionSignal() {
        // Si lo medido supera lo codificado es un pico de la cola vaciándose: no se sube por eso.
        XCTAssertEqual(AdaptiveBitRate.next(current: 6_000_000, measured: 20_000_000), 6_000_000)
    }

    func testInternetStreamsStartLowAndLocalOnesAtTheCeiling() {
        // Por RTMP (un pod al otro lado de internet) se arranca bajo y se sube si la red da;
        // por SRT (la red local) al techo, como siempre.
        XCTAssertEqual(StreamPublisher.startBitRate(for: URL(string: "rtmp://rig:x@1.2.3.4:1935/rig/izquierda")!, configured: 15_000_000), 4_000_000)
        XCTAssertEqual(StreamPublisher.startBitRate(for: URL(string: "rtmps://a.b/c")!, configured: 15_000_000), 4_000_000)
        XCTAssertEqual(StreamPublisher.startBitRate(for: URL(string: "rtmp://1.2.3.4/x")!, configured: 3_000_000), 3_000_000)
        XCTAssertEqual(StreamPublisher.startBitRate(for: URL(string: "srt://10.0.0.5:8890?streamid=x")!, configured: 15_000_000), 15_000_000)
    }

    func testHalvesWhenNothingWentOutAndNeverGoesBelowTheFloor() {
        XCTAssertEqual(AdaptiveBitRate.next(current: 8_000_000, measured: 0), 4_000_000)
        XCTAssertEqual(AdaptiveBitRate.next(current: 1_500_000, measured: 0), AdaptiveBitRate.minimumBitRate)
        XCTAssertEqual(AdaptiveBitRate.next(current: 15_000_000, measured: 100_000), AdaptiveBitRate.minimumBitRate)
    }
}

final class RecordingCleanupTests: XCTestCase {
    /// El borrado a mano (IOS-57: ya no se borra al empezar): solo los `.mov`.
    func testManualCleanupRemovesOnlyRecordings() throws {
        let manager = FileManager.default
        let carpeta = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: carpeta, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: carpeta) }

        // Dos sesiones viejas, una de ellas partida en dos por un corte.
        for nombre in ["left-1790000000.mov", "left-1790000000-2.mov", "right-1790000100.mov"] {
            manager.createFile(atPath: carpeta.appendingPathComponent(nombre).path, contents: Data())
        }
        // Y algo que no es una grabación: no se toca.
        manager.createFile(atPath: carpeta.appendingPathComponent("soporte.json").path, contents: Data())

        CaptureEngine.removeRecordings(in: carpeta.path)

        let quedan = try manager.contentsOfDirectory(atPath: carpeta.path).sorted()
        XCTAssertEqual(quedan, ["soporte.json"])
    }

    func testCleaningAnEmptyOrMissingFolderIsHarmless() {
        // La primera grabación del móvil: la carpeta está vacía, o ni existe.
        CaptureEngine.removeRecordings(in: FileManager.default.temporaryDirectory.path)
        CaptureEngine.removeRecordings(in: "/no/existe/esta/carpeta")
    }
}

