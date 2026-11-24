// giob.xc — a second object built with -c for giorder.xc (#649), with a
// global instance of its own.
extern i32 gLog;

class Circle : Object
    {
    i32 r;
    void init(void) { r = 3; gLog = gLog * 10 + 2; }
    i32 radius(void) { return r; }
    }

Circle gCircle;

i32 circleRadius(void) { return gCircle.radius(); }
