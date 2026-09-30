// UXFrameHud.xc — an on-screen frame-time readout: fps, and the fastest / last / slowest frame.
//
// The Metal-style HUD, for seeing what a device is actually doing: sample the frame clock every
// turn, keep the extremes over a rolling second, and draw them.  A view like any other -- add it to
// a window and call tick() from the per-turn code, toggle() to show or hide it -- so the toolkit
// needs no second frame source and the readout travels to every backend, which is the point: the
// developer machine is fast and the target phone is not.
//
// It asks for its OWN SURFACE, so on a backend with GL it lands OVER the map rather than under it
// (on one without, that is the decline and it draws inline).  Give it a small frame in a corner:
// the panel fills whatever bounds it is given.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXString.xc"
#import "UXViewDriver.xc"

// Microseconds as milliseconds to two decimals, e.g. 150 -> "0.15".  UXStr has no decimal point, so
// the hundredths are an integer and the point is pasted in; a value under 10 hundredths gets a
// leading zero, or "1.5" would read as "1.05".
u8* ux_frame_hud_ms(i32 us)
    {
    i32 h = us / (i32)10;
    if (h < (i32)0)
        {
        h = (i32)0;
        }
    i32 whole = h / (i32)100;
    i32 frac = h - whole * (i32)100;
    u8* fs = UXStr.fromInt(frac);
    if (frac < (i32)10)
        {
        fs = UXStr.append((u8*)"0", fs);
        }
    return UXStr.append(UXStr.append(UXStr.fromInt(whole), (u8*)"."), fs);
    }

class UXFrameHud : UXView
    {
    bool on;         // shown and sampling
    bool sampling;   // a first sample has started the clock
    i32 winStartUs;  // the rolling window's start (0 = not started)
    i32 lastUs;      // the previous sample's clock
    i32 prevUs;      // the last frame time
    i32 minUs;       // fastest frame this window
    i32 maxUs;       // slowest frame this window
    i32 winFrames;   // frames this window
    i32 fps;         // the last whole window's frame count

    void init(void)
        {
        super.init();
        on = false;
        sampling = false;
        winStartUs = (i32)0;
        lastUs = (i32)0;
        prevUs = (i32)0;
        minUs = (i32)0;
        maxUs = (i32)0;
        winFrames = (i32)0;
        fps = (i32)0;
        self.setOwnSurface(true); // over the map, where there is GL
        }

    void setEnabled(bool e)
        {
        on = e;
        sampling = false; // resample from the moment it is turned on
        // A view has no tree node until it is attached, so hiding or marking it before then would
        // touch a null receiver; the flag carries until attach, where it is visible by default.
        if (owner != (UXViewTree*)0)
            {
            self.setHidden(!e);
            if (e)
                {
                self.setNeedsDisplay();
                }
            }
        }
    bool isEnabled(void) { return on; }
    void toggle(void) { self.setEnabled(!on); }

    // Drop the extremes and start a fresh window (the fps number catches up next second).
    void reset(void)
        {
        sampling = false;
        fps = (i32)0;
        winFrames = (i32)0;
        minUs = (i32)0;
        maxUs = (i32)0;
        if (on)
            {
            self.setNeedsDisplay();
            }
        }

    // One frame boundary.  Call it from the app's per-turn code (the turn hook): the first call only
    // starts the clock, every later one is a frame, folded into the rolling second.
    void tick(void)
        {
        if (!on)
            {
            return;
            }
        i32 now = gDriver.nowUs();
        if (!sampling)
            {
            sampling = true;
            lastUs = now;
            winStartUs = now;
            winFrames = (i32)0;
            minUs = (i32)0;
            maxUs = (i32)0;
            return;
            }
        i32 dt = now - lastUs;
        lastUs = now;
        prevUs = dt;
        if (winFrames == (i32)0 || dt < minUs)
            {
            minUs = dt;
            }
        if (winFrames == (i32)0 || dt > maxUs)
            {
            maxUs = dt;
            }
        winFrames = winFrames + (i32)1;
        if (now - winStartUs >= (i32)1000000)
            {
            fps = winFrames;      // a whole second of frames
            winFrames = (i32)0;
            minUs = dt;           // the new window starts with this frame
            maxUs = dt;
            winStartUs = now;
            }
        self.setNeedsDisplay();
        }

    i32 framePrev(void) { return prevUs; }
    i32 frameMin(void) { return minUs; }
    i32 frameMax(void) { return maxUs; }
    i32 frameFps(void) { return fps; }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        if (!on)
            {
            return;
            }
        UXRect b = self.bounds();
        g.fillRectRGBA(b, (i32)0, (i32)0, (i32)0, (i32)168); // a dark translucent panel
        i32 x = (i32)b.x + (i32)6;
        i32 y = (i32)b.y + (i32)4;
        u8* l1 = UXStr.append(UXStr.fromInt(fps), (u8*)" fps");
        g.drawTextRGBA(l1, (i16)x, (i16)y, (i32)255, (i32)255, (i32)255, (i32)255, (i32)13);
        u8* l2 = UXStr.append(ux_frame_hud_ms(minUs), (u8*)" mn ");
        l2 = UXStr.append(l2, ux_frame_hud_ms(prevUs));
        l2 = UXStr.append(l2, (u8*)" pv ");
        l2 = UXStr.append(l2, ux_frame_hud_ms(maxUs));
        l2 = UXStr.append(l2, (u8*)" mx ");
        g.drawTextRGBA(l2, (i16)x, (i16)(y + (i32)16), (i32)170, (i32)220, (i32)255, (i32)255, (i32)12);
        }
    }
