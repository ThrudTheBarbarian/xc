// par_pin_cpus.xc — after a par block has run on the CPU, each thread's
// allowed CPUs (Linux: /proc/self/task/*/status), sorted, one line a thread:
// pinned, every lane holds one CPU of the process's set and the calling
// thread has its own set back (tests/driver/par-pin.sh).
#import "Stdio.xc"
#import "Par.xc"
#import "Files.xc"
#import "Directory.xc"

#define N 4096

i32 main(void)
    {
    u32* out = new u32[N];
    par pin
        {
        for (u32 i in 0..N)
            out[i] = i * (u32)3;
        }
    Array* tasks = Directory.list(String.withCString("/proc/self/task"));
    Array* lines = new Array();
    for (u32 t = (u32)0; tasks != (Array*)0 && t < tasks.count(); t = t + (u32)1)
        {
        String* st = Files.readText(String.withFormat("/proc/self/task/%s/status", ((DirEntry*)tasks.get(t)).name.cString()));
        if (st == (String*)0)
            continue;
        Array* ls = st.splitOnByte((u8)10);
        for (u32 k = (u32)0; k < ls.count(); k = k + (u32)1)
            {
            String* l = (String*)ls.get(k);
            if (l.hasPrefix(String.withCString("Cpus_allowed_list:")))
                lines.add((Object*)l.substringFromByte((u32)18).trimmed());
            }
        }
    for (u32 i = (u32)1; i < lines.count(); i = i + (u32)1)
        for (u32 j = i; j > (u32)0 && ((String*)lines.get(j)).compare((String*)lines.get(j - (u32)1)) < (i32)0; j = j - (u32)1)
            {
            Object* x = lines.get(j);
            lines.set(j, lines.get(j - (u32)1));
            lines.set(j - (u32)1, x);
            }
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
        Stdio.printf("%s\n", ((String*)lines.get(i)).cString());
    Stdio.printf("sum %u\n", out[N - 1] + out[1]);
    return 0;
    }
