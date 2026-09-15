#import "Stdio.xc"
class Res
    {
    i16 id;
    void dealloc()
        {
        Stdio.print("freed\n");
        }
    } i16 main()
    {
    Res* r;
    r = new Res;
    r.id = 9;
    return r.id;
    }
