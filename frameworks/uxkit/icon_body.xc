// icon_body.xc — the application-icon checks, shared by the backends that show a runtime icon.  The
// including file supplies iconPixel(x, y) -> 0xRRGGBB of the icon the platform now holds (-1 = none),
// iconW() / iconH(), and ICON_BACKEND; it boots its driver and calls iconBody(app).  Returns failures.
//
// The image is 64 x 64 with a colour per quadrant -- red top-left, green top-right, blue bottom-left,
// yellow bottom-right -- so a flipped or mirrored icon, or swapped channels, all show.

i32 gIconFails;
void ick(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%06x)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gIconFails = gIconFails + (i32)1;
        }
    }
bool near3(i32 c, i32 r, i32 g, i32 b)
    {
    if (c < (i32)0)
        {
        return false;
        }
    i32 dr = ((c >> (i32)16) & (i32)255) - r;
    i32 dg = ((c >> (i32)8) & (i32)255) - g;
    i32 db = (c & (i32)255) - b;
    // +-20 a channel: room for a platform's colour management (AppKit's reads back 14 off on blue),
    // and still far from any other quadrant's colour.
    return dr * dr <= (i32)400 && dg * dg <= (i32)400 && db * db <= (i32)400;
    }
void iconQuadrants(u8* how)
    {
    ick(iconW() == (i32)64 && iconH() == (i32)64, UXStr.append(how, (u8*)": the icon is 64 x 64"), iconW() * (i32)1000 + iconH());
    ick(near3(iconPixel((i32)10, (i32)10), (i32)230, (i32)30, (i32)30), UXStr.append(how, (u8*)": top-left is red (not flipped)"), iconPixel((i32)10, (i32)10));
    ick(near3(iconPixel((i32)54, (i32)10), (i32)30, (i32)200, (i32)60), UXStr.append(how, (u8*)": top-right is green (not mirrored)"), iconPixel((i32)54, (i32)10));
    ick(near3(iconPixel((i32)10, (i32)54), (i32)30, (i32)60, (i32)220), UXStr.append(how, (u8*)": bottom-left is blue (channels right)"), iconPixel((i32)10, (i32)54));
    ick(near3(iconPixel((i32)54, (i32)54), (i32)240, (i32)210, (i32)20), UXStr.append(how, (u8*)": bottom-right is yellow"), iconPixel((i32)54, (i32)54));
    }
u32 iconColour(i32 x, i32 y)
    {
    bool left = x < (i32)32;
    bool top = y < (i32)32;
    if (top && left) { return (u32)$FFE61E1E; }
    if (top) { return (u32)$FF1EC83C; }
    if (left) { return (u32)$FF1E3CDC; }
    return (u32)$FFF0D214;
    }
u8 gIconRGBA[16384]; // 64 x 64 x 4

i32 iconBody(UXApplication* app)
    {
    gIconFails = (i32)0;
    UXImage* img = UXImage.make((i32)64, (i32)64);
    for (i32 y = (i32)0; y < (i32)64; y = y + (i32)1)
        {
        for (i32 x = (i32)0; x < (i32)64; x = x + (i32)1)
            {
            img.setPixelRaw(x, y, iconColour(x, y));
            }
        }
    ick(app.setIcon(img), "setIcon(UXImage) is shown on this platform", (i32)0);
    iconQuadrants((u8*)"UXImage");
    // The same picture as RGBA bytes (a decoded PNG), through setIconPixels -- with the quadrants
    // swapped left for right, so this second icon is told from the first.
    for (i32 y = (i32)0; y < (i32)64; y = y + (i32)1)
        {
        for (i32 x = (i32)0; x < (i32)64; x = x + (i32)1)
            {
            u32 c = iconColour((i32)63 - x, y);
            i32 k = (y * (i32)64 + x) * (i32)4;
            gIconRGBA[k] = (u8)((c >> (u32)16) & (u32)255);
            gIconRGBA[k + (i32)1] = (u8)((c >> (u32)8) & (u32)255);
            gIconRGBA[k + (i32)2] = (u8)(c & (u32)255);
            gIconRGBA[k + (i32)3] = (u8)255;
            }
        }
    ick(app.setIconPixels(&gIconRGBA[(i32)0], (i32)64, (i32)64, (i32)UXPIX_RGBA), "setIconPixels(RGBA) is shown too", (i32)0);
    ick(near3(iconPixel((i32)10, (i32)10), (i32)30, (i32)200, (i32)60) && near3(iconPixel((i32)54, (i32)10), (i32)230, (i32)30, (i32)30),
        "RGBA: the new icon replaced the old (green top-left, red top-right)", iconPixel((i32)10, (i32)10));
    ick(near3(iconPixel((i32)10, (i32)54), (i32)240, (i32)210, (i32)20), "RGBA: bottom-left is yellow (channels right)", iconPixel((i32)10, (i32)54));
    if (gIconFails == (i32)0)
        {
        Stdio.printf("PASS: the application icon on %s -- set from a UXImage and from RGBA, the right way round\n", (u8*)ICON_BACKEND);
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gIconFails);
        }
    return gIconFails;
    }
