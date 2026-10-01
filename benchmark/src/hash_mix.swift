// hash_mix — an integer avalanche chain. See hash_mix.xc.

@main
struct HashMix {
    static func main() {
        var h = UInt32(CommandLine.arguments.count)
        let t0 = bench_now_us()
        for r in 0..<UInt32(640_000_000) {
            h = h ^ (h >> 16)
            h = h &* 2246822519
            h = h ^ (h >> 13)
            h = h &+ r
        }
        let t1 = bench_now_us()
        print("\(h) \(t1 - t0)")
    }
}
