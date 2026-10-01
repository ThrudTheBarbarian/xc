// call_depth — a small non-inlinable call chain in a hot loop. See call_depth.xc.

func leaf(_ x: UInt32) -> UInt32 { (x &* 3) ^ (x >> 2) }
func mid(_ x: UInt32) -> UInt32 { leaf(x) &+ leaf(x &+ 1) }
func outer(_ x: UInt32) -> UInt32 { mid(x) ^ mid(x &+ 2) }

@main
struct CallDepth {
    static func main() {
        let seed = UInt32(CommandLine.arguments.count)
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for r in 0..<UInt32(2_800_000_000) { acc = acc &+ outer(r &+ seed) }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
