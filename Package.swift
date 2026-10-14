// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "neotools",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "neodu", targets: ["neodu"]),
        .executable(name: "neodf", targets: ["neodf"]),
        .executable(name: "neofree", targets: ["neofree"]),
        .executable(name: "neotrash", targets: ["neotrash"]),
        .executable(name: "neolsof", targets: ["neolsof"]),
        .executable(name: "neofind", targets: ["neofind"]),
        .executable(name: "neonet", targets: ["neonet"]),
        .executable(name: "neotop", targets: ["neotop"]),
        .executable(name: "neomedia", targets: ["neomedia"]),
        .executable(name: "neodocs", targets: ["neodocs"]),
        .executable(name: "neotree", targets: ["neotree"]),
        .executable(name: "neops", targets: ["neops"]),
        .executable(name: "neo-setup", targets: ["neosetup"]),
    ],
    targets: [
        .target(name: "CShim"),
        // libwebp 1.6.0 (BSD-3-Clause, see Sources/CWebP/COPYING): macOS reads WebP but cannot write it
        .target(name: "CWebP", exclude: ["COPYING", "PATENTS"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .define("WEBP_USE_THREAD", to: "1")]),
        // libvpx 1.15.0 (BSD-3-Clause, see Sources/CVPX/COPYING): the VP8 / VP9 decoder, generic C, for WebM files that macOS cannot open
        .target(name: "CVPX", exclude: ["COPYING", "PATENTS"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .headerSearchPath("vpx"), .headerSearchPath("vpx_ports")]),
        // dav1d 1.5.1 (BSD-2-Clause, see Sources/CDAV1D/COPYING): the AV1 decoder, plain C
        .target(name: "CDAV1D", exclude: ["COPYING"], publicHeadersPath: "public",
                cSettings: [.headerSearchPath("include"), .headerSearchPath("."), .define("_GNU_SOURCE")]),
        // libvorbis 1.3.7 + the bit reader of libogg 1.3.5 (BSD-3-Clause, see Sources/CVORBIS/COPYING): the Vorbis decoder, for the sound of WebM and MKV files
        .target(name: "CVORBIS", exclude: ["COPYING", "COPYING-libogg"], publicHeadersPath: "public",
                cSettings: [.headerSearchPath("incl"), .headerSearchPath("lib")]),
        // dr_flac (public domain / MIT No Attribution, see Sources/CFLAC/COPYING): the FLAC decoder
        .target(name: "CFLAC", exclude: ["COPYING"], publicHeadersPath: "public", cSettings: [.headerSearchPath(".")]),
        // carquet 0.7.1 (MIT, Johan HG Natter, see Sources/CCARQUET/COPYING) with lz4 1.10.0 (BSD-2-Clause) and zstd 1.5.7 (BSD, single-file library): Parquet files; zlib is the system's
        .target(name: "CCARQUET", exclude: ["COPYING", "COPYING-lz4", "COPYING-zstd"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .define("ZSTD_DISABLE_ASM", to: "1")], linkerSettings: [.linkedLibrary("z")]),
        // NeoCore is what every command needs (terminal, text, scanner, units); the heavy frameworks live in the two modules below, so that
        // `neodu` does not load AVFoundation, Vision, PDFKit and AppKit just to start
        .target(name: "NeoCore", dependencies: ["CShim"], resources: [.process("Resources")]),
        .target(name: "TopKit", dependencies: ["NeoCore", "NetKit", "CShim"]),             // IOKit, IOReport: only neotop (it reads the interfaces through NetKit)
        .target(name: "NetKit", dependencies: ["NeoCore", "CShim"]),                       // SystemConfiguration: only neonet
        .target(name: "MicKit", dependencies: ["NeoCore"]),                                // CoreAudio: only `neolsof --mic`
        .target(name: "MediaKit", dependencies: ["NeoCore", "CWebP", "CVPX", "CDAV1D", "CVORBIS", "CFLAC"]),
        .target(name: "DocsKit", dependencies: ["NeoCore", "CCARQUET"]),
        .executableTarget(name: "neodu", dependencies: ["NeoCore"]),
        .executableTarget(name: "neodf", dependencies: ["NeoCore"]),
        .executableTarget(name: "neofree", dependencies: ["NeoCore"]),
        .executableTarget(name: "neotrash", dependencies: ["NeoCore"]),
        .executableTarget(name: "neolsof", dependencies: ["NeoCore", "MicKit"]),
        .executableTarget(name: "neofind", dependencies: ["NeoCore"]),
        .executableTarget(name: "neonet", dependencies: ["NeoCore", "NetKit"]),
        .executableTarget(name: "neotop", dependencies: ["NeoCore", "TopKit"]),
        .executableTarget(name: "neomedia", dependencies: ["NeoCore", "MediaKit"]),
        .executableTarget(name: "neodocs", dependencies: ["NeoCore", "DocsKit"]),
        .executableTarget(name: "neotree", dependencies: ["NeoCore"]),
        .executableTarget(name: "neops", dependencies: ["NeoCore"]),
        .executableTarget(name: "neosetup", dependencies: ["NeoCore"]),
        .testTarget(name: "NeoTests", dependencies: ["NeoCore", "MediaKit", "DocsKit", "TopKit", "NetKit", "MicKit", "CShim", "CCARQUET"]),
    ]
)
