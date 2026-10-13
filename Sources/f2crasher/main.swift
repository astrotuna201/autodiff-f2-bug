// Finding-2 minimal CRASH repro (the PERSISTENT, version-controlled copy).
// Tested originals: agent_temp/f2c/ladder/Sources/c3/main.swift and
// agent_temp/f2c/ladder/Sources/v3c2/main.swift (agent_temp is git-ignored;
// this file is the c3 shape: the 6-line kernel + three cross-component
// pullbacks below).
//
// WHAT IT DOES: at -O (release) this file does not compile — the Swift 6.4
// frontend hard-crashes in the LLVM verifier (Invalid bitcast: "ptr bitcast
// (double 1.000000e+00 to ptr)") while emitting the transformed module.
// At -Onone it builds and RUNS, printing AD=0.0 where REF=1.0 (the silent-
// zero face of the same bug — see porting-plan/tasks/ad-sensitivity-f2-minrepro.swift).
//
// Verified crash matrix (this file's shape, 2026-10-13):
//   - Swift 6.4.0.34.1 (Xcode 27.2 beta 27B5019j, arm64 macOS): CRASH,
//     LLVM verifier "Invalid bitcast", deterministic (x3 runs).
//   - Swift 6.4.0-RELEASE (swift.org toolchain, arm64 macOS): CRASH, same
//     verifier error.
//   - Swift 6.5-dev snapshots (2026-08-11-a, 2026-10-10-a): CRASH EARLIER,
//     "Assertion failed: (fn->getLoweredFunctionType() == type), function
//     getOrCreateFunction, file SILFunctionBuilder.cpp, line 38" in
//     SILModuleTransform "Differentiation" (i.e. the assert fires before
//     IRGen; the 6.4 verifier hit is the post-optimization surface of the
//     same malformed IR).
//   - 6.4.x at -Onone: builds; the array-element pullback is 0.0 (silent
//     zero), the const-scalar pullback is 0.0 (correct).
//
// MINIMALITY: three pullback sites (the reported threshold). A TWO-pull
// variant also crashes (drop the third pullback, g3). The ABSOLUTE minimal
// crasher is even smaller — the kernel can shrink to two lines with NO
// `cta:` writes at all (agent_temp/f2c/ladder/Sources/v3c2/main.swift):
//
//     @differentiable(reverse, wrt: x)
//     func k(_ x: [Double]) -> ([Double], Double) { return (x, 1.0) }
//
// plus two pullbacks (one on `.0[star]`, one on `.1`). The recorded trigger
// axes all hold: a `wrt [Double]` parameter, a 2-component tuple return
// whose array component is observed, a DEAD (constant) second component,
// and >=2 pullback sites in one module; the crash threshold is total
// transformed IR per module (this file crashes at 6 lines + 3 pulls, while
// the 1511-line production `gemBoxChain` crashes at 3 pulls and 2-pull
// variants of it do not).
//
// Context: Swift 6.4.0, imports _Differentiation 604.0.0 + Differentiation
// 3.1.0 (the registered subscript(cta:)). Cross-toolchain logs:
// f2-ad-crasher/logs/f2-crasher-*.log. Full record:
// porting-plan/tasks/ad-sensitivity-escalation.md §5.
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
    print(String(format: "c3 array-star-pullback  AD=% .9e  REF=% .9e  rel=% .2e  %@"
        , g1[star], ref1, rel1, ok1 ? "PASS" : "FAIL"))
    let rel2 = abs(g2[star] - ref2) / max(1.0, abs(ref2))
    let ok2 = rel2 < 1e-6 && g2[star] == g2[star]
    if !ok2 { fails += 1 }
    print(String(format: "c3 const-scalar-pullback  AD=% .9e  REF=% .9e  rel=% .2e  %@"
        , g2[star], ref2, rel2, ok2 ? "PASS" : "FAIL"))
    let rel3 = abs(g3[0] - ref3) / max(1.0, abs(ref3))
    let ok3 = rel3 < 1e-6 && g3[0] == g3[0]
    if !ok3 { fails += 1 }
    print(String(format: "c3 array-zero-pullback  AD=% .9e  REF=% .9e  rel=% .2e  %@"
        , g3[0], ref3, rel3, ok3 ? "PASS" : "FAIL"))
    return fails
}

let fails = gate()
