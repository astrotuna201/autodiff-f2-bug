# [Bug] Reverse-mode differentiation (`@differentiable(reverse)`) crashes the frontend at `-O` and silently miscompiles to zero at `-Onone` — 26-line repro, 3 `pullback` sites

(Paste-ready for **apple/swift**; the transform lives in the compiler's
Differentiation SIL pass. Filed against swift-differentiation-stdlib
`_Differentiation` 604.0.0 / Differentiation 3.1.0 — the library only
registers `subscript(cta:)`; the crash is in the compiler's reverse-mode
transform + IRGen.)

## Environment (all arm64, macOS 27)

| Toolchain | `swift --version` | Result at `-O` |
|---|---|---|
| Xcode 27.2 beta (27B5019j), Xcode-bundled | Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) | **CRASH** — LLVM verifier `Invalid bitcast` |
| swift.org 6.4.0-RELEASE standalone toolchain (`org.swift.640202609131a`) | Apple Swift 6.4 (swift-6.4-RELEASE) | **CRASH** — same verifier `Invalid bitcast` |
| 6.5-dev snapshot `swift-DEVELOPMENT-SNAPSHOT-2026-10-10-a` | 6.5 dev | **CRASH EARLIER** — `SILFunctionBuilder.cpp:38` assert in `SILModuleTransform "Differentiation"` |
| 6.5-dev snapshot `swift-DEVELOPMENT-SNAPSHOT-2026-08-11-a` | 6.5 dev | **CRASH EARLIER** — same assert |
| any of the above at `-Onone` (Debug) | — | builds; **silent miscompile**: array-element cotangent comes back `0.0` where the correct value is `1.0` |

Deterministic: same crash every run (verified x3).

## Minimal repro (crashes at `-O` with 3 pullback sites)

Build as a Swift 6 executable (swift-tools-version 6.4, language mode v6)
importing `_Differentiation` (binary, 604.0.0) and `Differentiation`
(3.1.0), compile with `-O`:

```swift
import Foundation
import _Differentiation
import Differentiation

@differentiable(reverse, wrt: x)
func kTiny(_ x: [Double]) -> ([Double], Double) {
    var a = x
    a[cta: star] = a[cta: star] + 0.25
    return (a, 1.0)
}

let n0 = 36
let x0 = (0 ..< n0).map { 1.0 + 0.1 * Double($0 % 7) }
let star = n0 / 2
let h = 1.0e-6

func gate() -> Int {
    var fails = 0
    var xp = x0; xp[star] += h
    var xm = x0; xm[star] -= h
    let g1 = pullback(at: x0, of: { (x: [Double]) in kTiny(x).0[star] })(1.0)
    let ref1 = (kTiny(xp).0[star] - kTiny(xm).0[star]) / (2 * h)
    let g2 = pullback(at: x0, of: { (x: [Double]) in kTiny(x).1 })(1.0)
    let ref2 = (kTiny(xp).1 - kTiny(xm).1) / (2 * h)
    let g3 = pullback(at: x0, of: { (x: [Double]) in kTiny(x).0[0] })(1.0)
    let ref3 = (kTiny(xp).0[0] - kTiny(xm).0[0]) / (2 * h)
    let rel1 = abs(g1[star] - ref1) / max(1.0, abs(ref1))
    let ok1 = rel1 < 1e-6 && g1[star] == g1[star]
    if !ok1 { fails += 1 }
    print(String(format: "c3 array-star-pullback  AD=% .9e  REF=% .9e  rel=% .2e  %@", g1[star], ref1, rel1, ok1 ? "PASS" : "FAIL"))
    let rel2 = abs(g2[star] - ref2) / max(1.0, abs(ref2))
    let ok2 = rel2 < 1e-6 && g2[star] == g2[star]
    if !ok2 { fails += 1 }
    print(String(format: "c3 const-scalar-pullback  AD=% .9e  REF=% .9e  rel=% .2e  %@", g2[star], ref2, rel2, ok2 ? "PASS" : "FAIL"))
    let rel3 = abs(g3[0] - ref3) / max(1.0, abs(ref3))
    let ok3 = rel3 < 1e-6 && g3[0] == g3[0]
    if !ok3 { fails += 1 }
    print(String(format: "c3 array-zero-pullback  AD=% .9e  REF=% .9e  rel=% .2e  %@", g3[0], ref3, rel3, ok3 ? "PASS" : "FAIL"))
    return fails
}

let fails = gate()
```

### Even smaller: 2 pullback sites, 2-line kernel, no `cta:` writes

```swift
import Foundation
import _Differentiation
import Differentiation

@differentiable(reverse, wrt: x)
func k(_ x: [Double]) -> ([Double], Double) {
    return (x, 1.0)
}

let n0 = 36
let x0 = (0 ..< n0).map { 1.0 + 0.1 * Double($0 % 7) }
let star = n0 / 2
let h = 1.0e-6

func gate() -> Int {
    var xp = x0; xp[star] += 1.0e-6
    var xm = x0; xm[star] -= 1.0e-6
    let g1 = pullback(at: x0, of: { (x: [Double]) in k(x).0[star] })(1.0)
    _ = (k(xp).0[star] - k(xm).0[star]) / (2 * 1.0e-6)
    let g2 = pullback(at: x0, of: { (x: [Double]) in k(x).1 })(1.0)
    _ = (k(xp).1 - k(xm).1) / (2 * 1.0e-6)
    return 0
}

let fails = gate()
```

This 2-pull variant crashes the 6.4 toolchains identically at `-O`.

### Bisection data (what is required / not required)

| Variant (1–3 pulls, `-Onone` unless noted) | Result |
|---|---|
| single array return (no tuple), 1 or 2 pulls | **correct** |
| 2-component tuple return, array component + **1** pull on it | **silent zero** (at `-Onone` AND `-O`) |
| tuple return, dead/constant 2nd component, 1 pull on array component | **silent zero** |
| tuple return, 2nd component with data flow (`return (a, a[0])`), 1 pull on array | **correct** |
| 1-pull on the constant scalar component only | correct (0 = 0) |
| 2 cross-component pulls (array + scalar component) | **silent zero** at `-Onone`; **frontend CRASH** at `-O` |
| 3 cross-component pulls | **silent zero** at `-Onone`; **frontend CRASH** at `-O` (6.4) / **SIL assert** (6.5-dev) |
| 2 pulls both on the same (array) component, tuple with dead 2nd component | builds at `-O`; silent zero on the written element (no crash) |

Non-monotonic in pull count: a 2-line no-write kernel with **3** pulls
builds at `-O` (silent zero) while the same kernel with **2** pulls
crashes — the trigger is total transformed IR in the module, not a simple
pull-count threshold. (The production 1511-line kernel with a
tuple `(state, metrics)` return needs ≥3 pull sites to crash.)

## Symptoms

1. **At `-O` (release) — deterministic frontend crash.** Two observed
   surfaces depending on kernel size:
   - small kernels: LLVM **verifier** failure after optimization:
     ```
     Invalid bitcast
     ptr bitcast (double 1.000000e+00 to ptr)
       %4 = bitcast double %0 to ptr, !dbg !1128
     <unknown>:0: error: fatal error encountered during compilation; please submit a bug report
     <unknown>:0: note: Broken module found, compilation aborted!
     0.  Running pass "verify" on module ".../main.o"
     ```
   - large kernels (e.g. the 1511-line production one): **IRGen** crash in
     `swift::irgen::reemitAsUnsubstituted` ← `emitApplyArgument` ←
     `visitFullApplySite` while emitting the transformed observable's
     VJP closure (SIGSEGV/SIGBUS/SIGILL variants); 6.5-dev snapshots hit
     `Assertion failed: (fn->getLoweredFunctionType() == type), function
     getOrCreateFunction, file SILFunctionBuilder.cpp, line 38` in
     `SILModuleTransform "Differentiation"` before IRGen.
2. **At `-Onone` (Debug) — silent miscompile**: build + run succeed, the
   array-element cotangent is `0.0` instead of `1.0` (nan in the full
   production kernel). A numerical differentiation (FD) reference in the
   same file shows `AD=0.000000e+00  REF=9.999999999e-01`.

## Notes

- The bug is in the compiler's reverse-mode differentiation transform for
  functions with a `wrt [Double]` (collection) parameter whose result is a
  multi-component value (tuple/struct) that **includes the array**, when
  ≥1 (silent) / ≥2 (crash) `pullback` sites for different components of
  that result exist in one module. The constant (dead) second component
  matters: making it data-flowing (`return (a, a[0])`) hides the
  single-pull miscompile.
- Plain `subscript` GET/SET without `cta:` does not compile in 6.4 for
  `wrt` array parameters ("cannot differentiate functions that have not
  been marked '@differentiable'" for the plain-subscript accessors), so
  the registered `subscript(cta:)` from Differentiation is the realistic
  access path — and it triggers this bug.
- Impact: reverse-mode AD through any such kernel is unusable at `-O`
  (build crash) and silently wrong at `-Onone`. We are forced to pin
  affected modules to `-Onone`.

Full build logs with complete frontend stack dumps and the exact
`swift-frontend` command lines are attached/available:
`f2-crasher-6.4.0.34.1-xcode272beta.log`,
`f2-crasher-6.4.0-RELEASE-swiftorg.log`,
`f2-crasher-6.5-dev-2026-10-10a.log`,
`f2-crasher-6.5-dev-2026-08-11a.log`,
`f2-crasher-chaingem-6.4-O.log`.
