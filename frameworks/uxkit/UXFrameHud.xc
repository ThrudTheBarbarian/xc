// UXFrameHud.xc — an on-screen frame-time readout: fps, and the fastest / average / slowest frame.
//
// The Metal-style HUD, for seeing what a device is actually doing: sample the frame clock every
// turn, and every whole second publish that second: its frame count (fps) and, for the SAME frames,
// the fastest, the average (the second's length over its frames, so exactly 1000/fps ms) and the
// slowest -- always min <= avg <= max.  One window for all four numbers: a single "last frame"
// sample is not shown, because the turn that repaints the readout is biased toward a long one.  A view like any other -- add it to
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
    i32 minUs;       // fastest frame in the window being gathered
    i32 maxUs;       // slowest frame in the window being gathered
    i32 winFrames;   // frames in the window being gathered
    i32 fps;         // the last WHOLE second: its frame count...
    i32 shownMinUs;  // ...its fastest frame
    i32 shownAvgUs;  // ...its average frame (its length / fps)
    i32 shownMaxUs;  // ...and its slowest frame

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
        shownMinUs = (i32)0;
        shownAvgUs = (i32)0;
        shownMaxUs = (i32)0;
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
        shownMinUs = (i32)0;
        shownAvgUs = (i32)0;
        shownMaxUs = (i32)0;
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
        if (winFrames == (i32)0 || dt < minUs) // the first frame of a window sets both extremes
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
            // Publish the whole second, all four numbers from the same frames, then start afresh.
            fps = winFrames;
            shownMinUs = minUs;
            shownMaxUs = maxUs;
            shownAvgUs = (now - winStartUs) / winFrames;
            winFrames = (i32)0;
            winStartUs = now;
            }
        self.setNeedsDisplay();
        }

    // The last whole second (see tick); framePrev is the latest single frame, for code that wants it.
    i32 framePrev(void) { return prevUs; }
    i32 frameMin(void) { return shownMinUs; }
    i32 frameAvg(void) { return shownAvgUs; }
    i32 frameMax(void) { return shownMaxUs; }
    i32 frameFps(void) { return fps; }

    // The second line, for a set of frame times.
    u8* timesLine(i32 mn, i32 av, i32 mx)
        {
        u8* l = UXStr.append(ux_frame_hud_ms(mn), (u8*)" min  ");
        l = UXStr.append(l, ux_frame_hud_ms(av));
        l = UXStr.append(l, (u8*)" avg  ");
        l = UXStr.append(l, ux_frame_hud_ms(mx));
        return UXStr.append(l, (u8*)" max");
        }
    // The width the readout needs, measured on this backend's font for the widest it can show
    // (three-digit fps, frame times to 999.99 ms), so the app can size the panel without guessing.
    i32 preferredWidth(void)
        {
        i32 a = gDriver.textWidth((u8*)"999 fps", (i32)13);
        i32 b = gDriver.textWidth(self.timesLine((i32)999990, (i32)999990, (i32)999990), (i32)12);
        return (a > b ? a : b) + (i32)12;
        }
    i32 preferredHeight(void) { return (i32)36; }

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
        u8* l2 = self.timesLine(shownMinUs, shownAvgUs, shownMaxUs);
        g.drawTextRGBA(l2, (i16)x, (i16)(y + (i32)16), (i32)170, (i32)220, (i32)255, (i32)255, (i32)12);
        }
    }
