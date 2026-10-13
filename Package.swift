// swift-tools-version: 6.4
//
// F2AdCrasher — the minimal, self-contained REPRO of "Finding 2": a Swift 6.4
// reverse-mode differentiation (`@differentiable(reverse)`) bug where a kernel
// with a `wrt [Double]` parameter returning a 2-component tuple `([Double],
// Double)` whose array component is observed miscompiles when one module has
// >=1 (silent zero) / >=2 (frontend crash) `pullback` sites on DIFFERENT
// components of that result (the second tuple component is dead/constant).
//
// ONE latent bug, FOUR faces (full bisection + corrected trigger boundary +
// cross-toolchain matrix: the crasher's own header in
// Sources/f2crasher/main.swift, issue.md, and the five canonical build logs in
// logs/):
//   - -Onone (any 6.4, macOS + Linux): builds + runs; the array-element
//     cotangent is 0.0 (silent miscompile).
//         swift build && ./.build/debug/f2crasher
//   - -O (6.4, this small kernel): DETERMINISTIC frontend crash — LLVM
//     verifier "Invalid bitcast".
//         swift build -c release          # crashes
//   - -O (6.4, large kernels): IRGen crash (the 152-line production shape).
//   - 6.5-dev (any opt, minimal size): SIL assert in the Differentiation pass.
//
// CROSS-PLATFORM dependency setup mirrors ../ad-sensitivity/Package.swift: the
// `_Differentiation` runtime is the swift-differentiation-stdlib 604.0.0
// XCFramework product on macOS (Apple-only slices; the OS toolchain no longer
// ships it since 26.4) and the toolchain-bundled stdlib module on Linux; the
// `Differentiation` 3.1.0 convenience layer supplies the registered
// `subscript(cta:)` + `pullback`. The Apple-only bits are `#if os(macOS)`-
// gated. CGENIE_USE_TOOLCHAIN_DIFF=1 swaps in the toolchain-bundled
// `_Differentiation` (needed for 6.5-dev builds).
import Foundation
import PackageDescription

#if os(macOS)
// Apple: the precompiled `_Differentiation` XCFramework product (Apple-only
// slices). CGENIE_USE_TOOLCHAIN_DIFF=1: use the TOOLCHAIN-BUNDLED module
// instead (the 6.5-dev snapshots ship it; the 604.0.0 XCFramework still
// compiles on 6.5-dev but the reworked `Array.DifferentiableView` API breaks
// the pinned swift-differentiation 3.1.0 CTAs — see ad-sensitivity §12.1).
let f2UseToolchainDiff = ProcessInfo.processInfo.environment["CGENIE_USE_TOOLCHAIN_DIFF"] == "1"
let f2Deps: [Target.Dependency] = f2UseToolchainDiff ? [] : [
    .product(name: "_Differentiation", package: "swift-differentiation-stdlib"),
]
// The binaryTarget framework is copied next to the built executable (the
// products dir). SwiftPM only reliably adds the runtime rpath to the FIRST
// executable that links it (a known quirk), so set it explicitly.
let f2LinkerSettings: [LinkerSetting] = f2UseToolchainDiff ? [] : [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"]),
]
#else
// Linux: `_Differentiation` is part of the swift.org toolchain's stdlib
// distribution — no product dep, no rpath.
let f2Deps: [Target.Dependency] = []
let f2LinkerSettings: [LinkerSetting] = []
#endif

let package = Package(
    name: "F2AdCrasher",
    platforms: [
        .macOS(.v27),
    ],
    dependencies: [
        // The precompiled `_Differentiation` XCFramework (Apple-only slices).
        // Declared on BOTH platforms to keep the resolved file's originHash
        // stable; on Linux no target links its product.
        .package(url: "https://github.com/differentiable-swift/swift-differentiation-stdlib", exact: "604.0.0"),
        // Convenience layer (portable source): re-exports `_Differentiation`
        // as `Differentiation` + helpers + the registered `subscript(cta:)`.
        // Its binary `_Differentiation` product dep is gated
        // `.when(platforms: [.macOS, .iOS])`, so on Linux that target compiles
        // against the toolchain stdlib module.
        .package(url: "https://github.com/differentiable-swift/swift-differentiation", exact: "3.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "f2crasher",
            dependencies: [
                .product(name: "Differentiation", package: "swift-differentiation"),
            ] + f2Deps,
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: f2LinkerSettings
        ),
    ]
)
