//xtc-warn: the local 'on' hides the field of the same name in Plane
//xtc-warn: the local 'up' hides the field of the same name in Jet
// A local named like a field of its class (or an ancestor) hides the field
// for the rest of its block. A parameter of the same name does not warn: that
// is how a setter is written.
#use Stdio

class Plane
    {
    u32 on;
    u32 up;

    void setOn(u32 on)
        {
        self.on = on;
        }

    u32 board(void)
        {
        u32 on = self.on + (u32)1;
        return on;
        }
    }

class Jet : Plane
    {
    u32 climb(void)
        {
        u32 up = (u32)3;
        return up;
        }
    }

i32 main(void)
    {
    Jet* j = new Jet();
    j.setOn((u32)1);
    Stdio.printf("%lu %lu\n", j.board(), j.climb());
    return 0;
    }
