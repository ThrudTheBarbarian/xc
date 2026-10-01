// poly_dispatch — dispatch through a mixed array of subclasses. See poly_dispatch.xc.

class Op {
    let k: UInt32
    init(_ x: UInt32) { k = x }
    func apply(_ v: UInt32) -> UInt32 { v &+ k }
}

final class OpMul: Op {
    override func apply(_ v: UInt32) -> UInt32 { v &* (k | 1) }
}

final class OpXor: Op {
    override func apply(_ v: UInt32) -> UInt32 { v ^ k }
}

@main
struct PolyDispatch {
    static func main() {
        let n = 256
        let seed = UInt32(CommandLine.arguments.count)
        var ops: [Op] = []
        ops.reserveCapacity(n)
        for i in 0..<n {
            let x = UInt32(i) &+ seed
            switch i % 3 {
            case 0:  ops.append(Op(x))
            case 1:  ops.append(OpMul(x))
            default: ops.append(OpXor(x))
            }
        }
        var acc: UInt32 = 1
        let t0 = bench_now_us()
        for r in 0..<UInt32(3_000_000) {
            for i in 0..<n { acc = ops[i].apply(acc) &+ r }
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
