// struct_copy — pass and return a small struct by value. See struct_copy.xc.

struct Pt {
    var x: UInt32
    var y: UInt32
}

func bump(_ p: Pt, _ d: UInt32) -> Pt {
    Pt(x: p.x &+ d, y: p.y ^ d)
}

@main
struct StructCopy {
    static func main() {
        let seed = UInt32(CommandLine.arguments.count)
        var acc: UInt32 = 0
        var p = Pt(x: seed, y: seed)
        let t0 = bench_now_us()
        for r in 0..<UInt32(2_200_000_000) {
            p = bump(p, r)
            acc = acc &+ p.x &+ p.y
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
