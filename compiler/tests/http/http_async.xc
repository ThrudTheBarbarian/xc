// Http.fetch, and url.fetch after Http.install, against the local server
// run.sh starts; each completion runs on its own thread and posts a Sem.
#use Stdio
#import "Http.xc"
#import "Sem.xc"

Sem* gDone = (Sem*)0;
u32 gStatus = (u32)0;
u32 gLen = (u32)0;

i32 main(void)
    {
    gDone = new Sem();
    Url* u = Url.withCString("http://127.0.0.1:18080/hello.txt");
    Http.fetch(u, block void(u32 status, String* body) {
        gStatus = status;
        gLen = body.byteLength();
        gDone.post();
        });
    gDone.wait();
    Stdio.printf("Http.fetch: %ld %ld\n", gStatus, gLen);

    Http.install();
    Url* v = Url.withCString("http://127.0.0.1:18080/sub/x.txt");
    v.fetch(block void(u32 status, String* body) {
        gStatus = status;
        gLen = body.byteLength();
        gDone.post();
        });
    gDone.wait();
    Stdio.printf("url.fetch: %ld %ld\n", gStatus, gLen);
    return 0;
    }
