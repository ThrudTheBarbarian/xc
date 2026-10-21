// The cases the non-literal format warning leaves alone: text printed through
// "%s", a literal format, and a built format given its arguments.
#use Stdio

i32 main(i32 argc, u8** argv)
    {
    u8* text = argv[0];
    u8* fmt = "%d\n";
    Stdio.printf("%s\n", text);
    Stdio.printf("plain\n");
    Stdio.printf(fmt, argc);
    return 0;
    }
