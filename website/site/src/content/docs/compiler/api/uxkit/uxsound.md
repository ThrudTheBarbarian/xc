---
title: UXSound
description: "Small noises made rather than loaded: oscillators, envelopes and filtered noise, rendered in xc and played by the backend."
---

`UXSound` makes a sound out of a few numbers (a waveform, a pitch and a slide, a
length, a volume) instead of loading a recording. It renders the samples in xc,
so the synthesis is the same on every backend and is tested headless. The driver
only plays the finished buffer. Sounds overlap: each is its own buffer, and the
platform mixes them.

```c
#use <UXKit>            // or #import "UXSound.xc"
```

## Overview

```c
UXSound* chime = new UXSound();
chime.note(UXSND_SINE, 880.0, 0.10, 0.07, 0.0, 0.0);    // 880 Hz for 100 ms
chime.note(UXSND_SINE, 1170.0, 0.14, 0.06, 0.0, 0.09);  // a second note, 90 ms in
chime.play();

UXSound* boom = new UXSound();
boom.boom(0.16, 0.0);
boom.play();
```

Build a sound once and play it as often as you like, including while it is
still playing: each play is a copy.

The shapes follow WebAudio, so sounds written for a browser port number for
number:
- **A note** is an oscillator whose frequency can ramp exponentially to
  `slideTo`, like `exponentialRampToValueAtTime`.
- **Its envelope** rises exponentially from silence to `vol` in 12 ms and falls
  exponentially back to silence at `secs`. A sound has no click at either end.
- **A boom** is white noise through a lowpass filter whose cutoff falls from
  900 Hz to 120 Hz, decaying over half a second.

The samples are 16-bit mono at 44.1 kHz.

| Backend | Plays through |
|---|---|
| macOS | `NSSound`, from an in-memory WAV |
| Windows | one `waveOut` stream per sound |
| Web | an `AudioBuffer` source per sound |
| Linux (GTK) | PulseAudio's simple API, loaded at run time (PipeWire serves it too) |
| iOS, Android, GEM | nothing yet: `play` answers false |

`play` answers false where a sound cannot play: no audio on that backend, no
sound server running on Linux, or, in a browser, before the person has clicked
or typed in the page. Browsers block audio until then, and UXKit resumes it on
the first gesture.

## Topics

**Building** · [note](#note) · [boom](#boom)
**Playing** · [play](#play)
**Samples** · [samples / frameCount](#samples--framecount)

### note

```c
UXSound* note(i32 kind, double hz, double secs, double vol, double slideTo, double at)
```

Adds a note: the waveform (`UXSND_SINE`, `UXSND_TRIANGLE`, `UXSND_SQUARE` or
`UXSND_SAWTOOTH`), its starting frequency in hertz, its length in seconds, its
peak volume from 0 to 1, the frequency it slides to (`0` for none), and when it
starts, in seconds from the start of the sound. Returns the sound, so notes can
be chained. A sound holds up to eight parts.

### boom

```c
UXSound* boom(double vol, double at)
```

Adds a boom (filtered noise, half a second long) at peak volume `vol`, starting
`at` seconds in. Its noise is seeded, so it is the same boom every time.

### play

```c
bool play(void)
```

Plays the sound now and returns at once. True when it started, false when this
backend cannot play it (see above).

### samples / frameCount

```c
i16* samples(void)
i32 frameCount(void)
```

The rendered samples, signed 16-bit mono at 44,100 a second, and how many there
are. The sound lasts until its last part ends, plus 20 ms.
