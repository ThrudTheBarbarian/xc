// arc_alloc — allocate an object per iteration and let ARC free it. See arc_alloc.xc.

final class Node {
    let v: UInt32
    init(_ x: UInt32) { v = x }
    func get() -> UInt32 { v }
}

@main
struct ArcAlloc {
    static func main() {
        let seed = UInt32(CommandLine.arguments.count)
        var acc: UInt32 = 0
        var keep = Node(seed)
        let t0 = bench_now_us()
        for r in 0..<UInt32(80_000_000) {
            let n = Node(r &+ seed)
            acc = (acc ^ n.get()) &+ keep.get()
            keep = n
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
