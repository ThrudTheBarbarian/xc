// UXBoot.xc — TEST SCAFFOLDING.  Not part of the toolkit.  Never used by a real app.
//
// On the board, init(1) runs the boot scripts off the SD card and one of them starts
// gemd with `&`.  Under qemu THE SD CARD IS NOT MOUNTED — so /bin/sh is missing, init
// runs no scripts, and NOBODY STARTS THE WINDOW SERVER.  libGEM then hard-exits with
// "no window server", which is correct: there is no single-process mode.
//
// So a test has to start gemd itself.  A real application must NEVER do this — it is
// exactly the "the desktop is not the server" mistake (RESPONSIBILITIES §4) written in
// miniature, and it lives here, in a file no shipped code imports.
#import <xtos>
#import <Stdio.xc>

class UXBoot
    {
    static bool ensureWindowServer(void)
        {
        i32 fd = sys_svc_connect("gem");
        // already up (the board)
        if (fd >= (i32)0)
            {
            sys_close(fd);
            return true;
            }

        u8* argv[2];
        argv[0] = "/bin/gemd";
        argv[1] = (u8*)0;
        i32 pid = sys_spawn("/bin/gemd", (i32)1, (pointer)&argv[0]);
        Stdio.printf("[boot] sys_spawn(/bin/gemd) -> %d\n", pid);
        if (pid < (i32)0)
            {
            return false;
            }

        // WAIT for it to register.  Spinning on a FAILING connect does not yield enough —
        // gemd has a plane to open, a theme to load and a service to bind, and the first
        // version of this gave up before it got there.  Sleep between tries.
        // up to 5 s
        for (i32 i = (i32)0; i < (i32)250; i++)
            {
            sys_nanosleep((u32)20000); // MICROseconds, and it takes ONE arg
            fd = sys_svc_connect("gem");
            if (fd >= (i32)0)
                {
                Stdio.printf("[boot] connected on try %d (fd %d)\n", i, fd);
                sys_close(fd);
                return true;
                }
            if (i % (i32)50 == (i32)0)
                {
                Stdio.printf("[boot] try %d: connect -> %d\n", i, fd);
                }
            }
        return false;
        }
    }
