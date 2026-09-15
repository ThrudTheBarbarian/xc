// UXProgressBar.xc — a bar that displays an UXProgress (NSProgressIndicator, determinate).
//
// Reads an UXProgress and fills the track to its fraction; indeterminate progress (zero total) draws a
// moving pip instead.  The fill-width arithmetic is pure and unit-testable; drawing rides the UXControl
// seam.  Pairs a progress model straight to the screen — a long UXOperationQueue reports through this.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXProgress.xc"

class UXProgressBar : UXControl
    {
    UXProgress* progress;
    i32 pipPhase; // 0..255 sweep position for the indeterminate pip
    void init(void)
        {
        super.init();
        progress = (UXProgress*)0;
        pipPhase = (i32)0;
        }
    // native NSProgressIndicator; drawRect is the GEM fallback
    UXKind kind(void)
        {
        return UXKindProgress;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self);
        }

    // ---- native-control bridge (output only: fraction 0..1000, or indeterminate) --------------
    i32 nativeFractionMille(void)
        {
        return progress == (UXProgress*)0 ? (i32)0 : progress.fractionMille();
        }
    i32 nativeIndeterminate(void)
        {
        return self.isIndeterminate() ? (i32)1 : (i32)0;
        }

    void setProgress(UXProgress* p)
        {
        progress = p;
        }
    // the run loop animates this for indeterminate
    void setPipPhase(i32 ph)
        {
        pipPhase = ph & (i32)255;
        }

    bool isIndeterminate(void)
        {
        return progress == (UXProgress*)0 || progress.isIndeterminate();
        }

    // Width of the filled portion for a track of width trackW, from the progress fraction (per mille).
    i32 filledWidth(i16 trackW)
        {
        if (progress == (UXProgress*)0)
            {
            return (i32)0;
            }
        return progress.fractionMille() * (i32)trackW / (i32)1000;
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        // The real Aristo2 progress bar (Cappuccino artwork): a rounded bezel trough, the blue "bar" fill
        // over the done portion, or the diagonally-striped fill when indeterminate.  (Native
        // NSProgressIndicator/progress32 on the other backends skip this drawRect.)
        g.drawTheme((u8*)"progress", UXGeom.make((i16)0, (i16)0, b.w, b.h));
        if (self.isIndeterminate())
            {
            g.drawTheme((u8*)"progress.indeterminate", UXGeom.make((i16)0, (i16)0, b.w, b.h));
            }
        else
            {
            i16 fw = (i16)self.filledWidth(b.w);
            if (fw > (i16)2)
                {
                g.drawTheme((u8*)"progress.bar", UXGeom.make((i16)0, (i16)0, fw, b.h));
                }
            }
        }
    }
