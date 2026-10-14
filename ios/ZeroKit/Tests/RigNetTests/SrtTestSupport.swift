import Darwin
import Foundation
import XCTest

import RigNet

/// Lo que comparten las pruebas de SRT: herramientas del Mac, procesos y puertos.
enum SrtTestSupport {
    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Un puerto UDP libre del loopback, para que dos pruebas no se pisen.
    static func freeUdpPort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(fd, $0, len)
                _ = getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// Lanza un proceso con la salida a un fichero. Se mata al acabar la prueba.
    static func launch(_ path: String, _ args: [String], stdout: URL, in test: XCTestCase) throws -> Process {
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = try FileHandle(forWritingTo: stdout)
        p.standardError = FileHandle.nullDevice
        try p.run()
        test.addTeardownBlock {
            guard p.isRunning else { return }
            p.terminate()
            // srt-live-transmit, reconectando, no siempre atiende a SIGTERM.
            for _ in 0..<20 where p.isRunning { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        return p
    }

    static func tempDir(_ test: XCTestCase) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("srt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Conecta reintentando mientras el otro lado arranca; un rechazo no se reintenta.
    static func connect(_ socket: SrtSocket, attempts: Int = 20, _ open: (SrtSocket) throws -> Void) throws {
        for intento in 1...attempts {
            do {
                try open(socket)
                return
            } catch SrtError.timeout where intento < attempts {
                continue
            } catch SrtError.connect where intento < attempts {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    /// `count` paquetes TS de relleno (PID 0x1FFF) con un contador en la carga: se ve si
    /// algo llega cambiado o desordenado.
    static func nullTsPackets(_ count: Int) -> Data {
        var out = Data(capacity: count * 188)
        for i in 0..<count {
            var p = [UInt8](repeating: 0xFF, count: 188)
            p[0] = 0x47
            p[1] = 0x1F
            p[2] = 0xFF
            p[3] = 0x10 | UInt8(i & 0x0F)
            withUnsafeBytes(of: UInt32(i).bigEndian) { p.replaceSubrange(4..<8, with: $0) }
            out.append(contentsOf: p)
        }
        return out
    }
}
