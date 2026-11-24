// giextra.xc — an object built with -c for a -static x86-64 link (#641):
// an array nothing reads, then a global instance, then a global that is
// read. The link's dead-data GC drops the object's data only as a whole, so
// the instance's header stays in front of it (gistatic.xc checks).
u8 gDead[40] = {1, 2, 3, 4, 5, 6, 7, 8};
class Spot : Object { i32 a; }
Spot gSpot;
u32 gNext = 99;
Spot* spot(void) { return &gSpot; }
u32 next(void) { return gNext; }
