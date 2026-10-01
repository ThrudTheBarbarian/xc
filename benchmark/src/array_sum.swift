// array_sum — sum an array. See array_sum.xc.

@main
struct ArraySum {
    static func main() {
        let n = 4096
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: n)
        for i in 0..<n { a[i] = (UInt32(i) &* 2654435761) &+ seed }
        var sum: UInt32 = 0
        let t0 = bench_now_us()
        for _ in 0..<UInt32(7_000_000) {
            for i in 0..<n { sum = sum &+ a[i] }
        }
        let t1 = bench_now_us()
        print("\(sum) \(t1 - t0)")
    }
}
