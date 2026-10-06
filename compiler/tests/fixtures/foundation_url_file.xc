//xtc-na: xt6502 — Url is not available on xt6502
// foundation_url_file.xc — Url's file URLs: making one from a path
// (escaping), recognising one, its decoded path, last component and
// extension, and percent-decoding edge cases.
#import "Foundation.xc"
#import "Url.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }
void show(Url* u)
    {
    String* fp = u.filePath();
    Stdio.printf("%s file=%d path=[%s] last=[%s] ext=[%s]\n", u.toString().cString(), (i32)(u.isFileURL() ? 1 : 0),
                 fp == 0 ? "-" : fp.cString(), u.lastPathComponent().cString(), u.pathExtension().cString());
    }

i32 main(void)
    {
    show(Url.fileURL(S("/Users/ada/My Docs/r\u00e9sum\u00e9 #2.txt")));
    show(Url.fileURL(S("/tmp/a%b?.tar.gz")));
    show(Url.fileURL(S("/")));
    show(Url.fileURL(S("C:\\Work\\notes.md")));
    show(Url.withCString("FILE:///etc/hosts"));
    show(Url.withCString("https://example.com/dir/page.html?x=1"));
    Stdio.printf("[%s]\n", Url.percentDecode(S("a%20b%2Fc%zz%4")).cString());
    return (i32)0;
    }
