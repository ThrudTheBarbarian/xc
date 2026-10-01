// string_scan — scan bytes for a delimiter and checksum them. See string_scan.xc.

@main
struct StringScan {
    static func main() {
        let n = 8192
        let seed = UInt32(CommandLine.arguments.count)
        var buf = [UInt8](repeating: 0, count: n)
        var acc: UInt32 = 0
        for i in 0..<n { buf[i] = UInt8(((UInt32(i) &* 31) &+ seed) & 127) }
        let t0 = bench_now_us()
        for _ in 0..<UInt32(3_800_000) {
            var count: UInt32 = 0
            for i in 0..<n {
                if buf[i] == UInt8(ascii: ",") { count = count &+ 1 }
                acc = acc &+ UInt32(buf[i])
            }
            acc = acc &+ count
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
