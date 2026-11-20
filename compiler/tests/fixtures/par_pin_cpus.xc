//xtc-na: xt6502 — no par runtime on this target (no ParDevice)
// par_pin_cpus.xc — after a par block has run on the CPU, each thread's
// allowed CPUs (Linux: /proc/self/task/*/status), sorted, one line a thread:
// pinned, every lane holds one CPU of the process's set and the calling
// thread has its own set back (tests/driver/par-pin.sh). With a CPU as its
// argument, the program first moves onto that CPU alone and then takes its
// set back, so the calling thread starts its first block on that CPU and the
// lanes are pinned from there (#460, #506).
#import "Stdio.xc"
#import "Par.xc"
#import "Files.xc"
#import "Directory.xc"

#define N 4096

#if OS_linux
i32 sched_getaffinity(i32 pid, u64 size, u8* mask);
i32 sched_setaffinity(i32 pid, u64 size, u8* mask);
#endif

i32 main(i32 argc, u8** argv)
    {
#if OS_linux
    if (argc > 1)
        {
        i32 start = 0;
        for (u8* p = argv[1]; *p >= '0' && *p <= '9'; p = p + 1)
            start = start * 10 + (*p - '0');
        u8 saved[128];
        u8 one[128];
        sched_getaffinity(0, 128, &saved[0]);
        for (u32 i = 0; i < 128; i = i + 1)
            one[i] = 0;
        one[start / 8] = 1 << (start % 8);
        sched_setaffinity(0, 128, &one[0]);
        sched_setaffinity(0, 128, &saved[0]);
        }
#endif
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
