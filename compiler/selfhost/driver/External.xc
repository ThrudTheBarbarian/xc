// External.xc — the pieces `--no-self-host` needs to hand a build to a vendor
// toolchain instead of this compiler's own assembler and linker.
// =================================================================
//
// The default path needs nothing installed: every target assembles, links and
// (on macOS) signs in-house. `--no-self-host` is the opt-in the other way, for
// checking a program against the platform toolchain: the host clang for arm64
// macOS, the NDK clang for android, arm-none-eabi-gcc for arm9. What it needs
// from this file:
//
//   * a way to run a program — `system()`, with every argument quoted, since
//     xtc has no process-spawning primitive of its own;
//   * the per-program C runtime stub each toolchain compiles beside the
//     assembly (the ARC/heap helpers are program-specific, so they are
//     generated from the symbols the assembly references);
//   * the Mach-O-to-ELF assembly rewrite the NDK assembler needs.
//
// Each generator mirrors its counterpart in the reference driver, so the two
// drivers hand the vendor tools the same inputs.

#import "Foundation.xc"
#import "Files.xc"

i32 system(u8* cmd);
i32 getpid(void);

class External
{
    u8 _unused; // no instances: every entry point is static

    void init(void)
    {
        _unused = (u8)0;
    }

    // One argument, quoted for a POSIX shell: inside single quotes nothing is
    // special except the quote itself, which becomes '\''.
    static String* quote(String* s)
    {
        String* out = String.withCString("'");
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)39) out.appendCString("'\\''");
            else out.appendByte(c);
        }
        out.appendCString("'");
        return out;
    }

    // Run argv[0] with the rest as its arguments, stdout and stderr passed
    // through. Returns the exit status, or -1 when it could not be run.
    static i32 run(Array* argv)
    {
        String* cmd = new String();
        for (u32 i = (u32)0; i < argv.count(); i = i + (u32)1) {
            if (i > (u32)0) cmd.appendByte((u8)' ');
            cmd.append(quote((String*)argv.get(i)));
        }
        i32 st = system(cmd.cString());
        if (st < (i32)0) return (i32)-1;
        // A wait status: the exit code in bits 8..15, a signal in 0..6.
        if ((st & (i32)127) != (i32)0) return (i32)128 + (st & (i32)127);
        return (st >> (i32)8) & (i32)255;
    }

    // This process's scratch directory, $TMPDIR (or /tmp)/xcc-<pid>, created on
    // first use. The FILE names inside it are fixed: the vendor compiler
    // records a C source's base name in the image's symbol table, so a stub
    // named after the pid would make every build differ.
    static String* tempDir()
    {
        String* dir = Platform.env(String.withCString("TMPDIR"));
        if (dir == (String*)0 || dir.byteLength() == (u32)0) dir = String.withCString("/tmp");
        String* p = String.withString(dir);
        if (!p.hasSuffix(String.withCString("/"))) p.appendByte((u8)'/');
        p.appendFormat("xcc-%ld", getpid());
        if (!Files.exists(p)) Files.createDirectory(p);
        return p;
    }

    static String* tempPath(string name)
    {
        String* p = tempDir();
        p.appendByte((u8)'/');
        p.appendCString(name);
        return p;
    }

    // Remove the scratch directory and everything in it.
    static void cleanup(void)
    {
        Array* a = new Array();
        a.add((Object*)String.withCString("rm"));
        a.add((Object*)String.withCString("-rf"));
        a.add((Object*)tempDir());
        run(a);
    }

    // Everything a shell command prints on stdout, or "" (stderr discarded).
    static String* captureAll(String* shellCmd)
    {
        String* out = tempPath("capture.txt");
        String* cmd = String.withString(shellCmd);
        cmd.appendCString(" > ");
        cmd.append(quote(out));
        cmd.appendCString(" 2>/dev/null");
        system(cmd.cString());
        String* t = Files.readText(out);
        remove(out);
        if (t == (String*)0) return String.withCString("");
        return t;
    }

    // Run argv with its stdout captured (stderr passes through), or 0 when it
    // could not be run or exited non-zero.
    static String* captureArgv(Array* argv)
    {
        String* out = tempPath("capture.txt");
        String* cmd = new String();
        for (u32 i = (u32)0; i < argv.count(); i = i + (u32)1) {
            if (i > (u32)0) cmd.appendByte((u8)' ');
            cmd.append(quote((String*)argv.get(i)));
        }
        cmd.appendCString(" > ");
        cmd.append(quote(out));
        i32 st = system(cmd.cString());
        String* t = Files.readText(out);
        remove(out);
        if (st != (i32)0) return (String*)0;
        if (t == (String*)0) return String.withCString("");
        return t;
    }

    static void remove(String* path)
    {
        Array* a = new Array();
        a.add((Object*)String.withCString("rm"));
        a.add((Object*)String.withCString("-f"));
        a.add((Object*)path);
        run(a);
    }

    // The element names that take the one-argument primitive allocator. The
    // list is the reference's XTIRIsPrimitiveElemName, i64/u64 included.
    static bool isPrimitive(String* s)
    {
        string names = "pointer bool i8 u8 i16 u16 i32 u32 i64 u64 float double string";
        Array* p = String.withCString(names).splitOnByte((u8)' ');
        for (u32 i = (u32)0; i < p.count(); i = i + (u32)1)
            if (((String*)p.get(i)).equals(s)) return true;
        return false;
    }

    static bool wordByte(u8 c)
    {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
            || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
    }

    // Every distinct `<prefix><ident>` suffix in first-seen order, ident being
    // [A-Za-z_][A-Za-z0-9_]*. `wordStart` asks for the regex's `\b` before the
    // prefix: the byte before it must not be a word byte.
    static Array* suffixesAfter(String* text, string prefixC, bool wordStart)
    {
        String* prefix = String.withCString(prefixC);
        Array* out = new Array();
        Set* seen = new Set();
        u32 n = text.byteLength();
        u32 pl = prefix.byteLength();
        u32 i = (u32)0;
        while (i + pl <= n) {
            bool hit = true;
            for (u32 k = (u32)0; k < pl; k = k + (u32)1)
                if (text.byteAt(i + k) != prefix.byteAt(k)) { hit = false; break; }
            if (hit && wordStart && i > (u32)0 && wordByte(text.byteAt(i - (u32)1))) hit = false;
            if (!hit) { i = i + (u32)1; continue; }
            u32 s = i + pl;
            u32 e = s;
            if (e < n) {
                u8 c0 = text.byteAt(e);
                if (wordByte(c0) && !(c0 >= (u8)'0' && c0 <= (u8)'9')) {
                    e = e + (u32)1;
                    while (e < n && wordByte(text.byteAt(e))) e = e + (u32)1;
                }
            }
            if (e > s) {
                String* suf = text.substringBytes(s, e - s);
                if (!seen.contains((Hashable*)suf)) { seen.add((Hashable*)suf); out.add((Object*)suf); }
                i = e;
            } else {
                i = i + (u32)1;
            }
        }
        return out;
    }

    static u32 primStride(String* s)
    {
        if (s.equals(String.withCString("u8")) || s.equals(String.withCString("i8"))
            || s.equals(String.withCString("bool"))) return (u32)1;
        if (s.equals(String.withCString("u16")) || s.equals(String.withCString("i16"))) return (u32)2;
        if (s.equals(String.withCString("u32")) || s.equals(String.withCString("i32"))
            || s.equals(String.withCString("float"))) return (u32)4;
        return (u32)8;
    }

    // The host runtime stub for arm64 (macOS, and android through the NDK):
    // console and float primitives, the libm wrappers, the program's `main`
    // around the renamed `xt_main` (not for a library), and the ARC/heap
    // helpers the assembly references. `asmText` is already main-renamed.
    static String* arm64StubSource(String* asmText, bool forLibrary)
    {
        String* s = String.withCString(
            "#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <math.h>\n");
        if (!forLibrary)
            s.appendCString("extern int xt_main(void);\nint main(void){ return xt_main(); }\n");
        s.appendCString("void _putc(uint8_t c){ putchar((int)c); }\n");
        s.appendCString("static void _xtc_truncf(double v,uint8_t p){char b[64];snprintf(b,sizeof b,\"%.*f\",(int)(p+1),v);size_t L=strlen(b);if(L)b[L-1]=0;fputs(b,stdout);}\n");
        s.appendCString("void _xtc_pf(float f){printf(\"%.6f\",(double)f);}\n");
        s.appendCString("void _xtc_pd(double d){printf(\"%.10f\",d);}\n");
        s.appendCString("void _xtc_pfp(float f,uint8_t p){ if(!p)printf(\"%.6f\",(double)f); else _xtc_truncf((double)f,p);}\n");
        s.appendCString("void _xtc_pdp(double d,uint8_t p){ if(!p)printf(\"%.10f\",d); else _xtc_truncf(d,p);}\n");
        s.appendCString("float  _xm_sqrtf(float x){return sqrtf(x);} double _xm_sqrt(double x){return sqrt(x);}\n");
        s.appendCString("float  _xm_sinf(float x){return sinf(x);} double _xm_sin(double x){return sin(x);}\n");
        s.appendCString("float  _xm_cosf(float x){return cosf(x);} double _xm_cos(double x){return cos(x);}\n");
        s.appendCString("float  _xm_tanf(float x){return tanf(x);} double _xm_tan(double x){return tan(x);}\n");
        s.appendCString("float  _xm_atanf(float x){return atanf(x);} double _xm_atan(double x){return atan(x);}\n");
        s.appendCString("float  _xm_lnf(float x){return logf(x);} double _xm_ln(double x){return log(x);}\n");
        s.appendCString("float  _xm_expf(float x){return expf(x);} double _xm_exp(double x){return exp(x);}\n");
        s.appendCString("float  _xm_powf(float a,float b){return powf(a,b);} double _xm_pow(double a,double b){return pow(a,b);}\n");
        if (asmText == (String*)0) return s;

        if (asmText.contains(String.withCString("_xtc_count")))
            s.appendCString("unsigned long _xtc_count(void*o){return *(unsigned long*)((uint8_t*)o-26);}\n");
        Array* sufs = suffixesAfter(asmText, "__xtc_new_", false);
        for (u32 i = (u32)0; i < sufs.count(); i = i + (u32)1) {
            String* suf = (String*)sufs.get(i);
            if (isPrimitive(suf)) {
                u32 st = primStride(suf);
                s.appendCString("void *_xtc_new_"); s.append(suf);
                s.appendFormat("(unsigned long n){unsigned long b=n*%luUL; if(b<256)b=256;", st);
                s.appendCString("uint8_t*p=(uint8_t*)calloc(1,b+38);");
                s.appendCString("if(!p){fprintf(stderr,\"xcc: out of memory (%lu elements)\\n\",n);abort();}");
                s.appendFormat("*(uint32_t*)(p+0)=0x58544F42U;*(unsigned long*)(p+4)=%luUL;*(unsigned long*)(p+12)=n;", st);
                s.appendCString("*(void(**)(void*))(p+20)=0;*(void**)(p+28)=0;*(uint16_t*)(p+36)=1;return p+38;}\n");
                continue;
            }
            String* deName = String.withCString("_");
            deName.append(suf); deName.appendCString("$dealloc:");
            bool hasDe = asmText.contains(deName);
            if (hasDe) { s.appendCString("extern void "); s.append(suf); s.appendCString("$dealloc(void*);\n"); }
            s.appendCString("void *_xtc_new_"); s.append(suf);
            s.appendCString("(unsigned long count,unsigned long stride){if(count<1)count=1;");
            s.appendCString("unsigned long b=count*stride; if(b<256)b=256;");
            s.appendCString("uint8_t*p=(uint8_t*)calloc(1,b+38);");
            s.appendCString("if(!p){fprintf(stderr,\"xcc: out of memory (%lu x %lu bytes)\\n\",count,stride);abort();}");
            s.appendCString("*(uint32_t*)(p+0)=0x58544F42U;*(unsigned long*)(p+4)=stride;*(unsigned long*)(p+12)=count;");
            if (hasDe) {
                s.appendCString("*(void(**)(void*))(p+20)=(void(*)(void*))&"); s.append(suf);
                s.appendCString("$dealloc;");
            } else {
                s.appendCString("*(void(**)(void*))(p+20)=0;");
            }
            s.appendCString("*(void**)(p+28)=0;*(uint16_t*)(p+36)=1;return p+38;}\n");
        }
        if (asmText.contains(String.withCString("__xtc_alloc"))) {
            s.appendCString("void *_xtc_alloc(unsigned long count,unsigned long stride,void(*dealloc)(void*)){");
            s.appendCString("if(count<1)count=1;unsigned long b=count*stride; if(b<256)b=256;");
            s.appendCString("uint8_t*p=(uint8_t*)calloc(1,b+38);");
            s.appendCString("if(!p){fprintf(stderr,\"xcc: out of memory (%lu x %lu bytes)\\n\",count,stride);abort();}");
            s.appendCString("*(uint32_t*)(p+0)=0x58544F42U;*(unsigned long*)(p+4)=stride;*(unsigned long*)(p+12)=count;");
            s.appendCString("*(void(**)(void*))(p+20)=dealloc;*(void**)(p+28)=0;*(uint16_t*)(p+36)=1;return p+38;}\n");
        }
        // Weak references are always supported: a library can hold a weak
        // slot to an object the application allocated, so every dealloc asks
        // the object's own header.
        if (asmText.contains(String.withCString("__xtc_dealloc"))) {
            s.appendCString("void _xtc_weak_zero_for(void*);\n");
            s.appendCString("void _xtc_dealloc(void *o){_xtc_weak_zero_for(o);");
            s.appendCString("uint8_t*base=(uint8_t*)o-38;");
            s.appendCString("unsigned long stride=*(unsigned long*)(base+4);unsigned long count=*(unsigned long*)(base+12);");
            s.appendCString("void(*d)(void*)=*(void(**)(void*))(base+20);");
            s.appendCString("if(d){*(unsigned short*)((uint8_t*)o-2)=0x8000u;");
            s.appendCString("for(unsigned long i=0;i<count;i++)d((uint8_t*)o+i*stride);}free(base);}\n");
        }
        s.appendCString("#define _XT_WH(o) (*(void***)((uint8_t*)(o)-10))\n");
        s.appendCString("void _xt_rt_lock(void); void _xt_rt_unlock(void);\n");
        s.appendCString("static void _xt_weak_unreg(void **slot){");
        s.appendCString("void ***pp=(void***)slot[-2]; if(!pp) return;");
        s.appendCString("void **nx=(void**)slot[-1];");
        s.appendCString("*pp=nx; if(nx) nx[-2]=(void*)pp;");
        s.appendCString("slot[-2]=0; slot[-1]=0;}\n");
        s.appendCString("void _xtc_weak_unregister(void **slot){");
        s.appendCString("_xt_rt_lock(); _xt_weak_unreg(slot); _xt_rt_unlock();}\n");
        s.appendCString("void _xtc_weak_register(void **slot,void *obj){");
        s.appendCString("_xt_rt_lock();");
        s.appendCString("_xt_weak_unreg(slot);");
        s.appendCString("if(!obj) { _xt_rt_unlock(); return; }");
        s.appendCString("if(*(uint32_t*)((uint8_t*)obj-38)!=0x58544F42U) { _xt_rt_unlock(); return; }");
        s.appendCString("void **nx=_XT_WH(obj);");
        s.appendCString("slot[-2]=(void*)&_XT_WH(obj); slot[-1]=(void*)nx;");
        s.appendCString("if(nx) nx[-2]=(void*)&slot[-1];");
        s.appendCString("_XT_WH(obj)=slot; _xt_rt_unlock();}\n");
        s.appendCString("void *_xtc_weak_load(void **slot){return *slot;}\n");
        s.appendCString("void _xtc_weak_zero_for(void *obj){if(!obj)return;");
        s.appendCString("_xt_rt_lock();");
        s.appendCString("void **s=_XT_WH(obj);");
        s.appendCString("while(s){void **nx=(void**)s[-1];");
        s.appendCString("*s=0; s[-2]=0; s[-1]=0; s=nx;}");
        s.appendCString("_XT_WH(obj)=0; _xt_rt_unlock();}\n");
        if (asmText.contains(String.withCString("__xtc_bank"))) {
            s.appendCString("static void *_xtc_bank_regions[3][256]={{0}};\n");
            s.appendCString("void *_xtc_bank(uint8_t type,uint8_t idx){if(type>1)return 0;");
            s.appendCString("if(!_xtc_bank_regions[type][idx])_xtc_bank_regions[type][idx]=calloc(1,12288);");
            s.appendCString("return _xtc_bank_regions[type][idx];}\n");
        }
        return s;
    }

    // The arm9 (XTOS loader) runtime stub: the loader calls `main(argc, argv)`,
    // so the stub owns `main`, records the arguments for Process.xc and calls
    // the renamed `xt_main`. ELF symbols are bare, and the object header uses
    // 4-byte fields (24 bytes in all).
    static String* arm9StubSource(String* asmText, bool forLibrary)
    {
        String* s = String.withCString(
            "#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n");
        if (!forLibrary) {
            s.appendCString("extern int xt_main(void);\n");
            s.appendCString("void _xt_capture_args(int,char**);\n");
            s.appendCString("int main(int argc, char **argv){ _xt_capture_args(argc, argv); return xt_main(); }\n");
        }
        if (asmText == (String*)0) return s;
        if (asmText.contains(String.withCString("_xtc_count")))
            s.appendCString("uint32_t _xtc_count(void*o){return *(uint32_t*)((uint8_t*)o-16);}\n");
        Array* sufs = suffixesAfter(asmText, "_xtc_new_", true);
        for (u32 i = (u32)0; i < sufs.count(); i = i + (u32)1) {
            String* suf = (String*)sufs.get(i);
            if (isPrimitive(suf)) {
                s.appendCString("void *_xtc_new_"); s.append(suf);
                s.appendCString("(unsigned long n){unsigned long b=n*8; if(b<256)b=256;");
                s.appendCString("uint8_t*p=(uint8_t*)calloc(1,b+24);");
                s.appendCString("if(!p){fprintf(stderr,\"xcc: out of memory (%lu elements)\\n\",n);abort();}");
                s.appendCString("*(uint32_t*)(p+0)=0x58544F42U;*(uint32_t*)(p+4)=8;*(uint32_t*)(p+8)=(uint32_t)n;");
                s.appendCString("*(void(**)(void*))(p+12)=0;*(void**)(p+16)=0;*(uint16_t*)(p+22)=1;return p+24;}\n");
                continue;
            }
            String* deName = String.withString(suf);
            deName.appendCString("$dealloc:");
            bool hasDe = asmText.contains(deName);
            if (hasDe) { s.appendCString("extern void "); s.append(suf); s.appendCString("$dealloc(void*);\n"); }
            s.appendCString("void *_xtc_new_"); s.append(suf);
            s.appendCString("(unsigned long count,unsigned long stride){if(count<1)count=1;");
            s.appendCString("unsigned long b=count*stride; if(b<256)b=256;");
            s.appendCString("uint8_t*p=(uint8_t*)calloc(1,b+24);");
            s.appendCString("if(!p){fprintf(stderr,\"xcc: out of memory (%lu x %lu bytes)\\n\",count,stride);abort();}");
            s.appendCString("*(uint32_t*)(p+0)=0x58544F42U;*(uint32_t*)(p+4)=(uint32_t)stride;*(uint32_t*)(p+8)=(uint32_t)count;");
            s.appendCString("*(void(**)(void*))(p+12)=");
            if (hasDe) { s.appendCString("(void(*)(void*))&"); s.append(suf); s.appendCString("$dealloc"); }
            else s.appendCString("0");
            s.appendCString(";*(void**)(p+16)=0;*(uint16_t*)(p+22)=1;return p+24;}\n");
        }
        if (asmText.contains(String.withCString("_xtc_alloc"))) {
            s.appendCString("void *_xtc_alloc(unsigned long count,unsigned long stride,void(*dealloc)(void*)){");
            s.appendCString("if(count<1)count=1;unsigned long b=count*stride; if(b<256)b=256;");
            s.appendCString("uint8_t*p=(uint8_t*)calloc(1,b+24);");
            s.appendCString("if(!p){fprintf(stderr,\"xcc: out of memory (%lu x %lu bytes)\\n\",count,stride);abort();}");
            s.appendCString("*(uint32_t*)(p+0)=0x58544F42U;*(uint32_t*)(p+4)=(uint32_t)stride;*(uint32_t*)(p+8)=(uint32_t)count;");
            s.appendCString("*(void(**)(void*))(p+12)=dealloc;*(void**)(p+16)=0;*(uint16_t*)(p+22)=1;return p+24;}\n");
        }
        if (asmText.contains(String.withCString("_xtc_dealloc"))) {
            s.appendCString("void _xtc_weak_zero_for(void*);\n");
            s.appendCString("void _xtc_dealloc(void *o){_xtc_weak_zero_for(o);");
            s.appendCString("uint8_t*base=(uint8_t*)o-24;");
            s.appendCString("unsigned long stride=*(uint32_t*)(base+4);unsigned long count=*(uint32_t*)(base+8);");
            s.appendCString("void(*d)(void*)=*(void(**)(void*))(base+12);");
            s.appendCString("if(d){*(unsigned short*)((uint8_t*)o-2)=0x8000u;");
            s.appendCString("for(unsigned long i=0;i<count;i++)d((uint8_t*)o+i*stride);}free(base);}\n");
        }
        s.appendCString("#define _XT_WH(o) (*(void***)((uint8_t*)(o)-8))\n");
        s.appendCString("void _xtc_weak_unregister(void **slot){");
        s.appendCString("void ***pp=(void***)slot[-2]; if(!pp) return;");
        s.appendCString("void **nx=(void**)slot[-1];");
        s.appendCString("*pp=nx; if(nx) nx[-2]=(void*)pp;");
        s.appendCString("slot[-2]=0; slot[-1]=0;}\n");
        s.appendCString("void _xtc_weak_register(void **slot,void *obj){");
        s.appendCString("_xtc_weak_unregister(slot);");
        s.appendCString("if(!obj) return;");
        s.appendCString("if(*(uint32_t*)((uint8_t*)obj-24)!=0x58544F42U) return;");
        s.appendCString("void **nx=_XT_WH(obj);");
        s.appendCString("slot[-2]=(void*)&_XT_WH(obj); slot[-1]=(void*)nx;");
        s.appendCString("if(nx) nx[-2]=(void*)&slot[-1];");
        s.appendCString("_XT_WH(obj)=slot;}\n");
        s.appendCString("void *_xtc_weak_load(void **slot){return *slot;}\n");
        s.appendCString("void _xtc_weak_zero_for(void *obj){if(!obj)return;");
        s.appendCString("void **s=_XT_WH(obj);");
        s.appendCString("while(s){void **nx=(void**)s[-1];");
        s.appendCString("*s=0; s[-2]=0; s[-1]=0; s=nx;}");
        s.appendCString("_XT_WH(obj)=0;}\n");
        if (asmText.contains(String.withCString("_xtc_bank"))) {
            s.appendCString("static void *_xtc_bank_regions[3][256]={{0}};\n");
            s.appendCString("void *_xtc_bank(uint8_t type,uint8_t idx){if(type>1)return 0;");
            s.appendCString("if(!_xtc_bank_regions[type][idx])_xtc_bank_regions[type][idx]=calloc(1,12288);");
            s.appendCString("return _xtc_bank_regions[type][idx];}\n");
        }
        return s;
    }

    // ── the Mach-O → ELF assembly rewrite (the NDK clang's dialect) ───────

    static bool symStart(u8 c)
    {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
            || c == (u8)'_' || c == (u8)'$' || c == (u8)'.';
    }
    static bool symByte(u8 c)
    {
        return symStart(c) || (c >= (u8)'0' && c <= (u8)'9');
    }

    // One leading underscore off every symbol: `_` preceded by start, space,
    // comma or `[`, and followed by a symbol-start byte.
    static String* stripUnderscore(String* l)
    {
        String* out = new String();
        u32 n = l.byteLength();
        u32 i = (u32)0;
        while (i < n) {
            u8 c = l.byteAt(i);
            if (c == (u8)'_' && i + (u32)1 < n && symStart(l.byteAt(i + (u32)1))) {
                bool atStart = i == (u32)0;
                u8 p = atStart ? (u8)' ' : l.byteAt(i - (u32)1);
                if (p == (u8)' ' || p == (u8)'\t' || p == (u8)',' || p == (u8)'['
                    || p == (u8)'\n' || p == (u8)'\r') {
                    out.appendByte(l.byteAt(i + (u32)1));
                    i = i + (u32)2;
                    continue;
                }
            }
            out.appendByte(c);
            i = i + (u32)1;
        }
        return out;
    }

    // `sym@SUFFIX` → pre + sym + post, for every symbol carrying the suffix.
    static String* reloc(String* l, string suffixC, string pre, string post)
    {
        String* suffix = String.withCString(suffixC);
        String* out = new String();
        u32 n = l.byteLength();
        u32 sl = suffix.byteLength();
        u32 i = (u32)0;
        u32 copied = (u32)0;
        while (i + sl <= n) {
            bool hit = true;
            for (u32 k = (u32)0; k < sl; k = k + (u32)1)
                if (l.byteAt(i + k) != suffix.byteAt(k)) { hit = false; break; }
            // `@PAGE` must not match the front of `@PAGEOFF`: the reference
            // rewrites the longer suffixes first, so by the time the short one
            // runs none of them remain. Same order here.
            if (!hit) { i = i + (u32)1; continue; }
            u32 s = i;
            while (s > copied && symByte(l.byteAt(s - (u32)1))) s = s - (u32)1;
            // The regex's leftmost match starts at the first symbol-START byte
            // of that run (a leading digit cannot begin one).
            while (s < i && !symStart(l.byteAt(s))) s = s + (u32)1;
            if (s == i) { i = i + (u32)1; continue; }
            out.append(l.substringBytes(copied, s - copied));
            out.appendCString(pre);
            out.append(l.substringBytes(s, i - s));
            out.appendCString(post);
            i = i + sl;
            copied = i;
        }
        out.append(l.substringBytes(copied, n - copied));
        return out;
    }

    static u32 decimal(String* s)
    {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9') break;
            v = v * (u32)10 + (u32)(c - (u8)'0');
        }
        return v;
    }

    // `.comm name, size[, log2]` split into its operands, or 0.
    static Array* commOperands(String* t)
    {
        if (!t.hasPrefix(String.withCString(".comm"))) return (Array*)0;
        String* rest = t.substringFromByte((u32)5);
        if (rest.byteLength() == (u32)0) return (Array*)0;
        u8 c = rest.byteAt((u32)0);
        if (c != (u8)' ' && c != (u8)'\t') return (Array*)0;
        Array* parts = rest.splitOnByte((u8)',');
        Array* out = new Array();
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            out.add((Object*)((String*)parts.get(i)).trimmed());
        if (out.count() < (u32)2 || out.count() > (u32)3) return (Array*)0;
        return out;
    }

    static String* machoToElfArm64(String* asmText, bool shared)
    {
        if (asmText == (String*)0) return String.withCString("");
        Array* out = new Array();
        String* section = String.withCString("    .text");
        Array* lines = asmText.splitOnByte((u8)'\n');
        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1) {
            String* l = (String*)lines.get(li);
            if (l.contains(String.withCString(".section"))) {
                if (l.contains(String.withCString("__TEXT,__cstring"))
                    || l.contains(String.withCString("__TEXT,__const"))
                    || l.contains(String.withCString("__DATA,__const")))
                    l = String.withCString("    .section .rodata");
                else if (l.contains(String.withCString("__DATA,__data")))
                    l = String.withCString("    .data");
                else if (l.contains(String.withCString("__mod_init_func")))
                    l = String.withCString("    .section .init_array,\"aw\",%init_array");
                else if (l.contains(String.withCString("__TEXT,__text")))
                    l = String.withCString("    .text");
            }
            l = stripUnderscore(l);
            l = reloc(l, "@GOTPAGEOFF", ":got_lo12:", "");
            l = reloc(l, "@GOTPAGE", ":got:", "");
            l = reloc(l, "@PAGEOFF", ":lo12:", "");
            l = reloc(l, "@PAGE", "", "");
            String* t = l.trimmed();
            Array* cm = commOperands(t);
            if (!shared) {
                if (cm != (Array*)0 && cm.count() == (u32)3) {
                    u32 lg = decimal((String*)cm.get((u32)2));
                    String* c = String.withCString("    .comm ");
                    c.append((String*)cm.get((u32)0)); c.appendByte((u8)',');
                    c.append((String*)cm.get((u32)1));
                    c.appendFormat(",%lu", (u32)1 << lg);
                    out.add((Object*)c);
                    continue;
                }
                out.add((Object*)l);
                continue;
            }
            if (t.hasPrefix(String.withCString(".text"))) section = String.withCString("    .text");
            else if (t.hasPrefix(String.withCString(".data"))) section = String.withCString("    .data");
            else if (t.hasPrefix(String.withCString(".section"))) section = l;
            if (cm != (Array*)0) {
                String* nm = (String*)cm.get((u32)0);
                u32 lg = (u32)3;
                if (cm.count() == (u32)3) lg = decimal((String*)cm.get((u32)2));
                String* g = String.withCString("    .globl "); g.append(nm); out.add((Object*)g);
                String* h = String.withCString("    .hidden "); h.append(nm); out.add((Object*)h);
                out.add((Object*)String.withCString("    .bss"));
                out.add((Object*)String.withFormat("    .p2align %lu", lg));
                String* lb = String.withString(nm); lb.appendByte((u8)':'); out.add((Object*)lb);
                String* z = String.withCString("    .zero "); z.append((String*)cm.get((u32)1)); out.add((Object*)z);
                out.add((Object*)section);
                continue;
            }
            out.add((Object*)l);
            if (t.hasPrefix(String.withCString(".globl"))) {
                String* rest = t.substringFromByte((u32)6);
                if (rest.byteLength() > (u32)0 && (rest.byteAt((u32)0) == (u8)' ' || rest.byteAt((u32)0) == (u8)'\t')) {
                    rest = rest.trimmed();
                    u32 e = (u32)0;
                    while (e < rest.byteLength() && symByte(rest.byteAt(e))) e = e + (u32)1;
                    if (e > (u32)0) {
                        String* h = String.withCString("    .hidden ");
                        h.append(rest.substringBytes((u32)0, e));
                        out.add((Object*)h);
                    }
                }
            }
        }
        String* joined = new String();
        for (u32 i = (u32)0; i < out.count(); i = i + (u32)1) {
            if (i > (u32)0) joined.appendByte((u8)'\n');
            joined.append((String*)out.get(i));
        }
        return joined;
    }
}
