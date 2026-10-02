// UXSound.xc — small noises, made rather than loaded: oscillators, envelopes and filtered noise,
// rendered to PCM in xc and handed to the driver to play.
//
// WHY SYNTHESIS IS NEUTRAL.  A sound here is a few numbers -- a waveform, a pitch and a slide, a
// length, a volume -- and turning those into samples is arithmetic, so it is the same code on every
// backend and it is tested headless (test_sound).  The driver's whole job is to PLAY a buffer
// (UXViewDriver.audioPlay): an in-memory WAV through NSSound on AppKit, one waveOut stream per sound
// on Windows, an AudioBuffer on the web.  Sounds overlap because each is its own buffer and the
// platform mixes them, so no toolkit code ever runs on an audio thread.
//
// THE SHAPES FOLLOW WEBAUDIO, because the sounds being ported were written for it: an oscillator
// with an exponential frequency ramp (OscillatorNode + exponentialRampToValueAtTime), a gain envelope
// that rises exponentially from 0.0001 to the volume in 12 ms and falls exponentially back to 0.0001
// at the end, and noise through a lowpass biquad whose cutoff falls exponentially (BiquadFilterNode,
// its Q of 1 dB).  A sound is a list of such parts, each at its own start offset, mixed into one
// buffer -- which is how a two-note chime is one sound and not a timer.
#import <Math.xc>
#import "UXViewDriver.xc" // gDriver, for play

#define UXSND_SINE 0
#define UXSND_TRIANGLE 1
#define UXSND_SQUARE 2
#define UXSND_SAWTOOTH 3
#define UXSND_NOISE 4    // white noise through a falling lowpass (a boom)
#define UXSND_RATE 44100 // samples a second, mono

// One voice of a sound.
class UXSoundPart
    {
    i32 kind;
    double hz;       // start frequency (for noise, the filter's start cutoff)
    double slideTo;  // 0 = no slide; else the frequency (cutoff) at the end, reached exponentially
    double secs;     // length of the envelope
    double vol;      // peak gain, 0..1
    double at;       // start offset in the sound, seconds
    bool attack;     // the 12 ms exponential rise (notes); noise starts at full volume
    void init(void)
        {
        kind = (i32)UXSND_SINE;
        hz = 440.0;
        slideTo = 0.0;
        secs = 0.1;
        vol = 0.1;
        at = 0.0;
        attack = true;
        }
    }

class UXSound
    {
    Array* parts;    // owns its parts (an object in a fixed-size array field would not be kept alive)
    i32 count;
    i16* pcm;        // rendered on demand
    i32 frames;
    u32 noiseSeed;
    void init(void)
        {
        count = (i32)0;
        parts = new Array();
        pcm = (i16*)0;
        frames = (i32)0;
        noiseSeed = (u32)$12345678;
        }

    // ---- building ------------------------------------------------------------------------------
    // A note: waveform, start pitch, length, peak volume, and the pitch it slides to (0 = none),
    // starting `at` seconds into the sound.  WebAudio's note(kind, hz, secs, vol, slideTo).
    UXSound* note(i32 kind, double hz, double secs, double vol, double slideTo, double at)
        {
        if (count >= (i32)8)
            {
            return self;
            }
        UXSoundPart* p = new UXSoundPart();
        p.kind = kind;
        p.hz = hz;
        p.secs = secs;
        p.vol = vol;
        p.slideTo = slideTo;
        p.at = at;
        parts.add(p);
        count = count + (i32)1;
        pcm = (i16*)0;
        return self;
        }
    // Noise through a lowpass falling from 900 Hz to 120 Hz, decaying over half a second: what a
    // distant explosion is made of.
    UXSound* boom(double vol, double at)
        {
        if (count >= (i32)8)
            {
            return self;
            }
        UXSoundPart* p = new UXSoundPart();
        p.kind = (i32)UXSND_NOISE;
        p.hz = 900.0;
        p.slideTo = 120.0;
        p.secs = 0.5;
        p.vol = vol;
        p.at = at;
        p.attack = false;
        parts.add(p);
        count = count + (i32)1;
        pcm = (i16*)0;
        return self;
        }

    UXSoundPart* part(i32 k)
        {
        return (UXSoundPart* ?)parts.get((u32)k);
        }

    // ---- rendering -----------------------------------------------------------------------------
    // Exponential ramp from a to b over n samples: the per-sample factor.
    static double rampFactor(double a, double b, i32 n)
        {
        if (n <= (i32)1 || a <= 0.0 || b <= 0.0)
            {
            return 1.0;
            }
        return Math.pow(b / a, 1.0 / (double)n);
        }
    u32 nextNoise(void)
        {
        u32 x = noiseSeed;
        x = x ^ (x << (u32)13);
        x = x ^ (x >> (u32)17);
        x = x ^ (x << (u32)5);
        noiseSeed = x;
        return x;
        }
    void renderPart(UXSoundPart* p, double* mix, i32 total)
        {
        i32 start = (i32)(p.at * (double)UXSND_RATE);
        i32 n = (i32)(p.secs * (double)UXSND_RATE);
        i32 tail = n + (i32)(0.02 * (double)UXSND_RATE); // WebAudio's o.stop(t + secs + 0.02)
        if (p.kind == (i32)UXSND_NOISE)
            {
            tail = n;
            }
        i32 atk = p.attack ? (i32)(0.012 * (double)UXSND_RATE) : (i32)0;
        double gain = p.attack ? 0.0001 : p.vol;
        double upK = UXSound.rampFactor(0.0001, p.vol, atk);
        double downK = UXSound.rampFactor(p.vol, 0.0001, n - atk);
        double f = p.hz;
        double fK = p.slideTo > 0.0 ? UXSound.rampFactor(p.hz, p.slideTo, n) : 1.0;
        double phase = 0.0;
        // the lowpass state (noise only): a biquad, its coefficients refreshed every 16 samples as
        // the cutoff falls
        double b0 = 0.0;
        double b1 = 0.0;
        double b2 = 0.0;
        double a1 = 0.0;
        double a2 = 0.0;
        double x1 = 0.0;
        double x2 = 0.0;
        double y1 = 0.0;
        double y2 = 0.0;
        for (i32 i = (i32)0; i < tail; i = i + (i32)1)
            {
            i32 o = start + i;
            if (o >= total)
                {
                break;
                }
            double s = 0.0;
            if (p.kind == (i32)UXSND_NOISE)
                {
                if ((i & (i32)15) == (i32)0)
                    {
                    // WebAudio's lowpass: w0 = 2 pi f / rate, alpha = sin(w0) / (2 * 10^(Q/20)), Q = 1 dB
                    double w0 = 6.283185307179586 * f / (double)UXSND_RATE;
                    double cw = Math.cos(w0);
                    double alpha = Math.sin(w0) / (2.0 * 1.1220184543019633);
                    double a0 = 1.0 + alpha;
                    b0 = ((1.0 - cw) / 2.0) / a0;
                    b1 = (1.0 - cw) / a0;
                    b2 = b0;
                    a1 = (-2.0 * cw) / a0;
                    a2 = (1.0 - alpha) / a0;
                    }
                // the source decays as (1 - i/n)^2, as the original buffer did
                double r = (double)(self.nextNoise() >> (u32)8) / 8388608.0 - 1.0;
                double env = 1.0 - (double)i / (double)n;
                double x0 = r * env * env;
                double y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
                x2 = x1;
                x1 = x0;
                y2 = y1;
                y1 = y0;
                s = y0;
                }
            else
                {
                if (p.kind == (i32)UXSND_SINE)
                    {
                    s = Math.sin(phase * 6.283185307179586);
                    }
                else if (p.kind == (i32)UXSND_TRIANGLE)
                    {
                    s = phase < 0.5 ? 4.0 * phase - 1.0 : 3.0 - 4.0 * phase;
                    }
                else if (p.kind == (i32)UXSND_SQUARE)
                    {
                    s = phase < 0.5 ? 1.0 : -1.0;
                    }
                else
                    {
                    s = 2.0 * phase - 1.0;
                    }
                phase = phase + f / (double)UXSND_RATE;
                phase = phase - (double)(i32)phase;
                }
            mix[o] = mix[o] + s * gain;
            // the envelope and the slide, one sample on
            if (i < atk)
                {
                gain = gain * upK;
                }
            else if (i < n)
                {
                gain = gain * downK;
                }
            if (i < n)
                {
                f = f * fK;
                }
            }
        }
    void render(void)
        {
        double end = 0.0;
        for (i32 k = (i32)0; k < count; k = k + (i32)1)
            {
            double e = self.part(k).at + self.part(k).secs + 0.02;
            end = e > end ? e : end;
            }
        frames = (i32)(end * (double)UXSND_RATE) + (i32)1;
        double* mix = new double[(u32)frames];
        for (i32 i = (i32)0; i < frames; i = i + (i32)1)
            {
            mix[i] = 0.0;
            }
        noiseSeed = (u32)$12345678; // the same sound every time, so it can be tested
        for (i32 k = (i32)0; k < count; k = k + (i32)1)
            {
            self.renderPart(self.part(k), mix, frames);
            }
        pcm = new i16[(u32)frames];
        for (i32 i = (i32)0; i < frames; i = i + (i32)1)
            {
            double v = mix[i] * 32767.0;
            pcm[i] = (i16)(v > 32767.0 ? 32767.0 : (v < -32768.0 ? -32768.0 : v));
            }
        }
    // Play it now: rendered once, then handed to the driver, which copies it.  false where the
    // backend has no audio (see UXViewDriver.audioPlay).  A sound can be played again, and played
    // while it is still playing -- the copies overlap.
    bool play(void)
        {
        if (count == (i32)0 || gDriver == (UXViewDriver*)0)
            {
            return false;
            }
        return gDriver.audioPlay(self.samples(), self.frameCount(), (i32)UXSND_RATE);
        }
    // The rendered samples (signed 16-bit mono at UXSND_RATE) and how many.
    i16* samples(void)
        {
        if (pcm == (i16*)0)
            {
            self.render();
            }
        return pcm;
        }
    i32 frameCount(void)
        {
        if (pcm == (i16*)0)
            {
            self.render();
            }
        return frames;
        }
    }
