// GImage.h — Netpbm P7 (PAM) decode/encode + classic mono ICONBLK rendering.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Decode a binary P7 PAM (GRAY / GRAY_ALPHA / RGB / RGB_ALPHA) to an NSImage.
NSImage* _Nullable GImageFromPAM(NSData* data);

// Encode an NSImage as a binary P7 PAM, RGB_ALPHA (depth 4).
NSData* _Nullable GPAMFromImage(NSImage* image);

// Render a classic mono ICONBLK (1bpp data + optional mask, rows padded to a
// 16-bit boundary) to an NSImage: set data bit -> black, mask governs alpha.
NSImage* _Nullable GImageFromMono(NSData* data, NSData* _Nullable mask, int w, int h);

// Expand one version of an Atari colour icon (CICONBLK) to an RGBA P7 PAM.
//
// `data` is PLANAR: `planes` consecutive bitplanes per row, each row padded to a
// 16-bit boundary; a pixel's colour index is assembled from its bit in each
// plane, plane 0 the least significant.  `mask` is 1 bpp and drives alpha.
// `palette` is 256 RGB triples (0..255) mapping colour index -> colour; pass NULL
// to use the standard VDI palette for that depth.
//
// A CICONBLK cannot carry alpha or true colour, so this is a widening: the result
// is exactly representable, and the original bytes are kept elsewhere for
// re-export.
NSData* _Nullable GPAMFromPlanar(NSData* data, NSData* _Nullable mask,
                                 int w, int h, int planes,
                                 const uint8_t* _Nullable palette /* 256*3 */);

// Render a classic BITBLK: 1bpp, `wb` bytes per row, `hl` rows.  A set bit is
// drawn in VDI pen `color`; a clear bit is transparent (a BITBLK has no mask).
NSImage* _Nullable GImageFromBitblk(NSData* data, int wb, int hl, int color);

// An AES mouse cursor.  A cursor bank (EmuTOS's mform.rsc / emucurs*.rsc) stores
// each MFORM inside a BITBLK of exactly 16x37 *words*:
//
//     WORD  mf_xhot, mf_yhot, mf_nplanes, mf_bg, mf_fg
//     UWORD mf_mask[16]
//     UWORD mf_data[16]
//
// Rendered 16x16: a mask bit makes the pixel opaque, a data bit picks fg over bg.
// GBitblkIsMform() spots the shape; hotX/hotY may be NULL.
BOOL GBitblkIsMform(NSData* _Nullable data, int wb, int hl);
NSImage* _Nullable GImageFromMform(NSData* data, int* _Nullable hotX, int* _Nullable hotY);

NS_ASSUME_NONNULL_END
