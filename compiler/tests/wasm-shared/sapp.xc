#use Stdio
#import <SLib>
i32 main(void)
    {
    printf("lenOwn %lu\n", SLib.lenOwn());
    String* s = String.withCString("abcdef");
    printf("lenOf  %lu\n", SLib.lenOf(s));
    return (i32)0;
    }
