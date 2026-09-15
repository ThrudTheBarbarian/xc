// enums.xc — enum member values
#import "Stdio.xc"

enum suits = {hearts, clubs, diamonds, spades};
enum priority = {low=1, medium, high, critical=10};

void main(void)
{
    u8 clubsV    = clubs;	// 1
    u8 diamondsV = diamonds;	// 2
    u8 spadesV   = spades;	// 3
    u8 mediumV   = medium;	// 2
    u8 highV     = high;	// 3
    u8 criticalV = critical;	// 10

    Stdio.printf("%d %d %d %d %d %d\n",
        (i16)clubsV, (i16)diamondsV, (i16)spadesV,
        (i16)mediumV, (i16)highV, (i16)criticalV);
}
