// xtopt.xc — run the ported IR optimiser over IR text.
// =================================================================
//
//   xtopt <in.ir> -m <target> -O<n> [--stop-after <pass>] [-o out.ir]
//
// The mirror of `xtcg-<arch> -O<n> --dump-opt-ir`, and compared against it by
// `selfhost/tools/opt-diff.sh`. A pass the port does not have yet exits 3 and
// names it, so an unported pass never masquerades as a clean diff.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"
#import "Opt.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    String* target = String.withCString("arm64");
    String* stopAfter = (String*)0;
    u32 level = (u32)0;
    u32 simdBytes = (u32)16;
    bool simdDispatch = false; // --simd=auto: runtime SIMD dispatch clones
    bool matMul = false;       // --matmul: idiom-matmul's kernel for the target
    String* simdName = String.withCString("base");
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o")) && i + (u32)1 < argc)
            {
            output = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-m")) && i + (u32)1 < argc)
            {
            target = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("--stop-after")) && i + (u32)1 < argc)
            {
            stopAfter = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-O0")))
            {
            level = (u32)0;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-O1")) || a.equals(String.withCString("-O")))
            {
            level = (u32)1;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-O2")))
            {
            level = (u32)2;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-O3")))
            {
            level = (u32)3;
            i = i + (u32)1;
            continue;
            }
        // --simd=avx2: the 32-byte vector width the x86-64 profile takes under
        // -mavx2, as the reference's --simd does (opt-diff's OPT_SIMD).
        // --matmul: the matrix kernels, as the reference's code generators
        // take it (arm64 SME; x86-64 one per vector tier).
        if (a.equals(String.withCString("--matmul")))
            {
            matMul = true;
            i = i + (u32)1;
            continue;
            }
        if (a.hasPrefix(String.withCString("--simd=")))
            {
            simdBytes = a.substringFromByte((u32)7).equals(String.withCString("avx512")) ? (u32)64
                      : a.substringFromByte((u32)7).equals(String.withCString("avx2")) ? (u32)32 : (u32)16;
            simdDispatch = a.substringFromByte((u32)7).equals(String.withCString("auto"));
            String* lv = a.substringFromByte((u32)7);
            simdName = (lv.equals(String.withCString("avx512")) || lv.equals(String.withCString("avx2"))
                        || lv.equals(String.withCString("auto"))) ? lv : String.withCString("base");
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtopt <in.ir> -m <target> -O<n> [-o out.ir]\n");
        Process.exit((i32)2);
        return;
        }
    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtopt: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtopt: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    OptProfile* prof = OptProfile.forTarget(target);
    prof.setVectorLaneBytes(simdBytes);
    prof.setSimdDispatch(simdDispatch);
    if (matMul && target.equals(String.withCString("arm64")))
        prof.setMatMul(String.withCString("__xt_sme_gemm_"), String.withCString(""));
    else if (matMul && target.equals(String.withCString("x86_64")))
        {
        String* suffix = String.withCString("_");
        suffix.append(simdName);
        prof.setMatMul(String.withCString("__xt_x86_gemm_"), suffix);
        }
    Opt* o = Opt.atLevel(level, prof);
    if (stopAfter != 0)
        o.setStopAfter(stopAfter);
    o.run(m);
    if (o.failed())
        {
        Stdio.printf("xtopt: %s: unsupported: %s\n", input.cString(),
                     o.why() == 0 ? "?" : o.why().cString());
        Process.exit((i32)3);
        return;
        }

    String* out = m.text();
    if (output == 0)
        {
        Stdio.printf("%s", out.cString());
        return;
        }
    if (!Files.writeText(output, out))
        {
        Stdio.printf("xtopt: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
