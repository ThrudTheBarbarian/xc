// xtos.xt — host (arm64) TYPES + syscalls for #import <xtos>, matching the POSIX shim.
// addr@16
struct os_fbinfo
    {
    i32 w;
    i32 h;
    i32 stride;
    pointer addr;
    }
    struct os_event
    {
    i32 type;
    i32 mx;
    i32 my;
    i32 button;
    i32 key;
    i32 shift;
    i32 wheel;
    } i32 sys_svc_connect(u8 @name);
i32 sys_close(i32 fd);
i32 sys_spawn(u8 @path, i32 argc, pointer argv);
i32 sys_nanosleep(u32 usec);
i32 sys_fb_info(pointer fi);
i32 sys_fb_wallpaper(pointer fi);
i32 sys_input(pointer ev, i32 timeout_ms, i32 raw);
