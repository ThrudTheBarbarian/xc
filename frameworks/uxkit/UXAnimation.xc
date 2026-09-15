// UXAnimation.xc — a timed value interpolation with easing (NSAnimation / CAMediaTimingFunction).
//
// Given a from/to value, a start time and a duration, valueAt(now) returns the interpolated value,
// shaped by an easing curve (linear / ease-in / ease-out / ease-in-out).  The run loop ticks a timer
// and reads valueAt each frame to move a property; before the start it reads `from`, after the end
// `to`.  Integer maths (t and eased value run 0..255), so it is exact and testable without a clock.
#import "Array.xc"

#define UX_EASE_LINEAR 0
#define UX_EASE_IN 1
#define UX_EASE_OUT 2
#define UX_EASE_IN_OUT 3

class UXAnimation
    {
    i32 fromVal;
    i32 toVal;
    i32 startMs;
    i32 durationMs;
    i32 easing;
    void init(void)
        {
        fromVal = (i32)0;
        toVal = (i32)0;
        startMs = (i32)0;
        durationMs = (i32)1;
        easing = (i32)UX_EASE_LINEAR;
        }

    static UXAnimation* make(i32 from, i32 to, i32 startMs, i32 durationMs, i32 easing)
        {
        UXAnimation* a = new UXAnimation();
        a.fromVal = from;
        a.toVal = to;
        a.startMs = startMs;
        a.durationMs = durationMs < (i32)1 ? (i32)1 : durationMs;
        a.easing = easing;
        return a;
        }

    // Easing curves over t in 0..255, returning 0..255.
    static i32 ease(i32 mode, i32 t)
        {
        if (t < (i32)0)
            {
            t = (i32)0;
            }
        if (t > (i32)255)
            {
            t = (i32)255;
            }
        if (mode == (i32)UX_EASE_IN)
            {
            return t * t / (i32)255;
            }
        if (mode == (i32)UX_EASE_OUT)
            {
            i32 u = (i32)255 - t;
            return (i32)255 - u * u / (i32)255;
            }
        if (mode == (i32)UX_EASE_IN_OUT)
            {
            if (t < (i32)128)
                {
                return (i32)2 * t * t / (i32)255;
                }
            i32 u = (i32)255 - t;
            return (i32)255 - (i32)2 * u * u / (i32)255;
            }
        return t; // linear
        }

    // Fraction of the animation complete at `now`, as 0..255 (before easing).
    i32 rawProgress(i32 now)
        {
        if (now <= startMs)
            {
            return (i32)0;
            }
        if (now >= startMs + durationMs)
            {
            return (i32)255;
            }
        return (now - startMs) * (i32)255 / durationMs;
        }
    // Eased fraction, 0..255.
    i32 progress(i32 now)
        {
        return UXAnimation.ease(easing, self.rawProgress(now));
        }

    // The interpolated value at `now`.
    i32 valueAt(i32 now)
        {
        if (now <= startMs)
            {
            return fromVal;
            }
        if (now >= startMs + durationMs)
            {
            return toVal;
            }
        i32 e = self.progress(now);
        return fromVal + (toVal - fromVal) * e / (i32)255;
        }
    bool isFinished(i32 now)
        {
        return now >= startMs + durationMs;
        }
    }
