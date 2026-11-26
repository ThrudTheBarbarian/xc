// An f4 array's elements are nibbles: no initialiser list lays them out.
// xtc: error "an f4 array takes no initialiser list: its elements are nibbles; assign them one by one"
#import "Stdio.xc"

f4 g[3] = {1.0, 2.0, 3.0};

i32 main(void)
{
    Stdio.printf("%f\n", g[1]);
    return 0;
}
