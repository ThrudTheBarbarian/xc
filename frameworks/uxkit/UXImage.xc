// UXImage.xc — an in-memory bitmap (NSBitmapImageRep in shape).
//
// A width x height grid of packed 0xAARRGGBB pixels with get/set, fill, fillRect and blit.  The model
// behind the image well, canvas layers and thumbnails; a backend uploads/draws these, but the pixel
// arithmetic (compositing a sub-image in, clearing a region) lives here and is testable.  Reuses
// UXColor for pack/unpack.
#import "Array.xc"
#import "UXColor.xc"

class UXImage
    {
    i32 w;
    i32 h;
    u32* px; // w*h pixels, row-major, 0xAARRGGBB
    void init(void)
        {
        w = (i32)0;
        h = (i32)0;
        px = (u32*)0;
        }

    static u32 pack(UXColor* c)
        {
        return ((u32)c.a << (u32)24) | ((u32)c.r << (u32)16) | ((u32)c.g << (u32)8) | (u32)c.b;
        }
    static UXColor* unpack(u32 v)
        {
        return UXColor.rgba((i32)((v >> (u32)16) & (u32)255), (i32)((v >> (u32)8) & (u32)255),
                            (i32)(v & (u32)255), (i32)((v >> (u32)24) & (u32)255));
        }

    static UXImage* make(i32 width, i32 height)
        {
        UXImage* im = new UXImage();
        if (width < (i32)1)
            {
            width = (i32)1;
            }
        if (height < (i32)1)
            {
            height = (i32)1;
            }
        im.w = width;
        im.h = height;
        im.px = new u32[(u32)(width * height)];
        return im;
        }
    i32 width(void)
        {
        return w;
        }
    i32 height(void)
        {
        return h;
        }
    bool inBounds(i32 x, i32 y)
        {
        return x >= (i32)0 && y >= (i32)0 && x < w && y < h;
        }

    void setPixelRaw(i32 x, i32 y, u32 v)
        {
        if (self.inBounds(x, y))
            {
            px[y * w + x] = v;
            }
        }
    u32 pixelRaw(i32 x, i32 y)
        {
        return self.inBounds(x, y) ? px[y * w + x] : (u32)0;
        }
    void setPixel(i32 x, i32 y, UXColor* c)
        {
        self.setPixelRaw(x, y, UXImage.pack(c));
        }
    UXColor* pixelAt(i32 x, i32 y)
        {
        return UXImage.unpack(self.pixelRaw(x, y));
        }

    void fill(UXColor* c)
        {
        u32 v = UXImage.pack(c);
        for (i32 i = (i32)0; i < w * h; i = i + (i32)1)
            {
            px[i] = v;
            }
        }
    void fillRect(i32 rx, i32 ry, i32 rw, i32 rh, UXColor* c)
        {
        u32 v = UXImage.pack(c);
        for (i32 y = ry; y < ry + rh; y = y + (i32)1)
            {
            for (i32 x = rx; x < rx + rw; x = x + (i32)1)
                {
                if (self.inBounds(x, y))
                    {
                    px[y * w + x] = v;
                    }
                }
            }
        }
    // Copy `src` into self with its top-left at (dx, dy); clipped to bounds.
    void blit(UXImage* src, i32 dx, i32 dy)
        {
        if (src == (UXImage*)0)
            {
            return;
            }
        for (i32 y = (i32)0; y < src.h; y = y + (i32)1)
            {
            for (i32 x = (i32)0; x < src.w; x = x + (i32)1)
                {
                i32 tx = dx + x;
                i32 ty = dy + y;
                if (self.inBounds(tx, ty))
                    {
                    px[ty * w + tx] = src.px[y * src.w + x];
                    }
                }
            }
        }
    UXImage* subImage(i32 rx, i32 ry, i32 rw, i32 rh)
        {
        UXImage* out = UXImage.make(rw, rh);
        for (i32 y = (i32)0; y < rh; y = y + (i32)1)
            {
            for (i32 x = (i32)0; x < rw; x = x + (i32)1)
                {
                out.px[y * rw + x] = self.pixelRaw(rx + x, ry + y);
                }
            }
        return out;
        }
    }
