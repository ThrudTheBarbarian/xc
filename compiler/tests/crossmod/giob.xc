// giob.xc — a second object built with -c for giorder.xc (#649), with a
// global instance of its own.
#import "Stdio.xc"

class Circle : Object
    {
    i32 r;
    void init(void) { r = 3; Stdio.printf("circle set up\n"); }
    i32 radius(void) { return r; }
    }

Circle gCircle;

i32 circleRadius(void) { return gCircle.radius(); }
