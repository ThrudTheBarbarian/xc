// Blocking GETs against the local server run.sh starts: a file, a redirect,
// a 404 and a refused connection.
#use Stdio
#import "Http.xc"

i32 main(void)
    {
    HttpResponse* r = Http.get(Url.withCString("http://127.0.0.1:18080/hello.txt"));
    Stdio.printf("status %ld type %s\n", r.status(), r.header(String.withCString("content-type")).cString());
    Stdio.printf("body [%s]\n", r.bodyString().cString());
    HttpResponse* d = Http.get(Url.withCString("http://127.0.0.1:18080/sub"));
    Stdio.printf("redirect -> %ld %s\n", d.status(), d.url().toString().cString());
    HttpResponse* m = Http.get(Url.withCString("http://127.0.0.1:18080/missing"));
    Stdio.printf("missing %ld\n", m.status());
    HttpResponse* e = Http.get(Url.withCString("http://127.0.0.1:1/"));
    Stdio.printf("refused %ld err %s\n", e.status(), e.error().cString());
    return 0;
    }
