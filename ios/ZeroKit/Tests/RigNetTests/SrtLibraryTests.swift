import RigNet
import XCTest

/// Que el xcframework propio enlaza y es el que toca (IOS-55).
final class SrtLibraryTests: XCTestCase {
    func testArrancaYEsLaVersionDelScript() {
        XCTAssertTrue(SrtLibrary.start())
        XCTAssertTrue(SrtLibrary.start(), "arrancar dos veces no hace nada")
        // SRT_VERSION de tools/build_libsrt.sh.
        XCTAssertEqual(SrtLibrary.version, "1.5.7")
    }
}
