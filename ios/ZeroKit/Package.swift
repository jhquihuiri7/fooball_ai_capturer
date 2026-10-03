// swift-tools-version: 6.0
// ZeroKit: las tres capas nativas de la app (IOS-02, plan de dos móviles).
//
//   RigCore  — Swift puro, solo Foundation. Swift 6 estricto desde el principio
//              (decisión 17 del plan): es lo que se replica contra los dorados del
//              servidor y lo que algún día correrá en Windows con el toolchain de Swift.
//   RigMedia — lo que toca AVFoundation, Metal, Core ML y VideoToolbox.
//   RigNet   — Network y, más adelante, libsrt.
//
// Capas: RigCore no importa a nadie; RigMedia y RigNet solo a RigCore. Lo vigila
// tools/check_layers.sh, la réplica del .importlinter del servidor.

import PackageDescription

let package = Package(
    name: "ZeroKit",
    platforms: [
        // macOS también: RigCoreTests y RigMediaTests corren en el Mac con
        // `swift test`, sin simulador. CoreVideo existe en las dos plataformas.
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "RigCore", targets: ["RigCore"]),
        .library(name: "RigMedia", targets: ["RigMedia"]),
        .library(name: "RigNet", targets: ["RigNet"]),
    ],
    targets: [
        .target(
            name: "RigCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RigMedia",
            dependencies: ["RigCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RigNet",
            dependencies: ["RigCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RigCoreTests",
            dependencies: ["RigCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RigMediaTests",
            dependencies: ["RigMedia"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
