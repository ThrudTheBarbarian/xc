// Platform.home() is the user's home directory on every desktop target:
// $HOME, else %USERPROFILE%. Windows has no HOME, so a win64 program got ""
// and built relative paths (Astronomancy, 2026-10-24). Only whether it is
// set is printed, so the output is the same on every host.
#import "Stdio.xc"
#import "Platform.xc"
i32 main(void)
    {
    String* h = Platform.home();
    Stdio.printf("home set: %d\n", h.byteLength() > (u32)0 ? 1 : 0);
    return 0;
    }
