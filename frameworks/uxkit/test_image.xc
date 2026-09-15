// test_image.xc — UXImage: pixel get/set, fill, fillRect, blit, subImage.
#import <Stdio.xc>
#import "UXImage.xc"
#import "UXColor.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
i32 redAt(UXImage* im, i32 x, i32 y)
    {
    return im.pixelAt(x, y).r;
    }
i32 blueAt(UXImage* im, i32 x, i32 y)
    {
    return im.pixelAt(x, y).b;
    }

void main(void)
    {
    gFails = (i32)0;

    UXImage* im = UXImage.make((i32)10, (i32)8);
    check("width", im.width(), (i32)10);
    check("height", im.height(), (i32)8);

    // set/get a pixel
    im.setPixel((i32)5, (i32)3, UXColor.red());
    check("pixel r", redAt(im, (i32)5, (i32)3), (i32)255);
    check("pixel b", blueAt(im, (i32)5, (i32)3), (i32)0);
    check("neighbour untouched", redAt(im, (i32)4, (i32)3), (i32)0);

    // alpha survives pack/unpack
    im.setPixel((i32)0, (i32)0, UXColor.rgba((i32)10, (i32)20, (i32)30, (i32)128));
    check("unpacked r", im.pixelAt((i32)0, (i32)0).r, (i32)10);
    check("unpacked a", im.pixelAt((i32)0, (i32)0).a, (i32)128);

    // out-of-bounds is a safe no-op / zero
    im.setPixel((i32)100, (i32)100, UXColor.red());
    check("oob read is transparent black", im.pixelAt((i32)100, (i32)100).r, (i32)0);

    // fill
    im.fill(UXColor.blue());
    check("filled centre blue", blueAt(im, (i32)5, (i32)5), (i32)255);
    check("filled corner blue", blueAt(im, (i32)0, (i32)0), (i32)255);
    check("fill overwrote the red pixel", redAt(im, (i32)5, (i32)3), (i32)0);

    // fillRect (clipped)
    im.fillRect((i32)2, (i32)2, (i32)3, (i32)3, UXColor.red());
    check("inside rect is red", redAt(im, (i32)3, (i32)3), (i32)255);
    check("outside rect still blue", blueAt(im, (i32)0, (i32)0), (i32)255);
    check("rect edge just outside", redAt(im, (i32)5, (i32)2), (i32)0);

    // blit a 2x2 green tile at (7,1)
    UXImage* tile = UXImage.make((i32)2, (i32)2);
    tile.fill(UXColor.green());
    im.blit(tile, (i32)7, (i32)1);
    check("blit landed (green)", im.pixelAt((i32)7, (i32)1).g, (i32)255);
    check("blit landed 2nd px", im.pixelAt((i32)8, (i32)2).g, (i32)255);
    check("outside blit unchanged (blue)", blueAt(im, (i32)9, (i32)5), (i32)255);

    // blit clipped at the edge (no crash, only in-bounds copied)
    im.blit(tile, (i32)9, (i32)7);
    check("clipped blit corner", im.pixelAt((i32)9, (i32)7).g, (i32)255);

    // subImage extraction
    UXImage* sub = im.subImage((i32)2, (i32)2, (i32)3, (i32)3);
    check("subimage size w", sub.width(), (i32)3);
    check("subimage copied the red rect", sub.pixelAt((i32)1, (i32)1).r, (i32)255);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXImage — pixel get/set, alpha, bounds, fill, fillRect, blit (clipped), subImage.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
