#import "Stdio.xc"
#import <optlib>
void main(void)
    {
    Bag* b = new Bag();
    b.init();
    b.add(new Object());
    b.add(new Object());
    Stdio.printf("size=%d\n", b.size());
    }
