// lnclient.xc — the client half of lib-name.sh.
#use <LnLib>
#import "Stdio.xc"

i32 main(void)
{
    LnBox* b = new LnBox();
    b.v = 21;
    Stdio.printf("%d\n", b.twice());
    return 0;
}
