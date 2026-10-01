// baseline — startup only. See baseline.xc.

@main
struct Baseline {
    static func main() {
        print("\(UInt32(CommandLine.arguments.count)) 0")
    }
}
