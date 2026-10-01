// method_call — a virtual method call per iteration. See method_call.xc.

class Shape {
    let k: UInt32
    init(_ x: UInt32) { k = x }
    func score(_ x: UInt32) -> UInt32 { k ^ x }
}

final class Boxy: Shape {
    override func score(_ x: UInt32) -> UInt32 { (k ^ x) &+ 1 }
}

@main
struct MethodCall {
    static func main() {
        let seed = UInt32(CommandLine.arguments.count)
        let s: Shape = (CommandLine.arguments.count & 1) != 0 ? Shape(seed) : Boxy(seed)
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for r in 0..<UInt32(1_600_000_000) { acc = acc &+ s.score(r) }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
