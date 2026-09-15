// XTAggInitRelay.m — see the header for why this exists.
#import "XTAggInitRelay.h"
#import "XTIRLayout.h"
#import "XTIRType.h"

@implementation XTAggInitRelay

// Backend footprint of a type: an aggregate is the sum of its (recursively
// sized) fields, anything else is whatever the backend says the leaf is.
+ (NSUInteger)backendSizeOf:(XTIRType*)t
                widthOfLeaf:(NSUInteger (^)(XTIRType*))widthOfLeaf
    {
    if (t.kind == XTIRTypeKindAgg && t.layout)
        {
        NSUInteger total = 0;
        for (XTIRLayoutField* f in t.layout.fields)
            total += [self backendSizeOf:f.type widthOfLeaf:widthOfLeaf];
        // Honour the padded layout size (bug 015): a struct's trailing alignment
        // pad is part of its footprint, so an array of it (and the read stride)
        // uses the padded size — the DST cursor must advance by it too.
        if (total < t.layout.size)
            total = t.layout.size;
        return total;
        }
    return widthOfLeaf(t);
    }

// Width of a field in the *IR* image. XTIRType.byteWidth reports 0 for Ptr and
// Agg, so read the width off the layout itself — the gap to the next field's
// offset (or to the layout's end for the last one). That keeps the pointer
// width whatever the front end chose for this target (2 or 3) without having
// to re-derive it.
+ (NSUInteger)irWidthOfField:(NSUInteger)idx inLayout:(XTIRLayout*)lay
    {
    XTIRLayoutField* f = lay.fields[idx];
    NSUInteger end = (idx + 1 < lay.fields.count)
                         ? lay.fields[idx + 1].byteOffset
                         : lay.size;
    return (end > f.byteOffset) ? end - f.byteOffset : 0;
    }

+ (void)relayInto:(uint8_t*)dst
           dstLen:(NSUInteger)dstLen
        dstOffset:(NSUInteger)dstOffset
             from:(const uint8_t*)src
           srcLen:(NSUInteger)srcLen
        srcOffset:(NSUInteger)srcOffset
           layout:(XTIRLayout*)lay
      widthOfLeaf:(NSUInteger (^)(XTIRType*))widthOfLeaf
        bigEndian:(BOOL)bigEndian
    {
    // The destination is addressed at the SAME recorded field offsets as the
    // source — the front end lays fields out once (with the per-target
    // field-alignment cap, blewit #5) and the backends read the layout
    // verbatim, so the relay's remaining jobs are the endianness flip and
    // tolerating a leaf whose backend width differs from the image's span.
    // (It used to advance a private prefix-sum cursor, a third offset model
    // that only agreed with the backends while everything packed tightly.)
    for (NSUInteger i = 0; i < lay.fields.count; i++)
        {
        XTIRLayoutField* f = lay.fields[i];
        XTIRType* t = f.type;
        NSUInteger srcOff = srcOffset + f.byteOffset;
        NSUInteger dstCur = dstOffset + f.byteOffset;
        NSUInteger dstW = [self backendSizeOf:t widthOfLeaf:widthOfLeaf];

        if (t.kind == XTIRTypeKindAgg && t.layout)
            {
            [self relayInto:dst
                     dstLen:dstLen
                  dstOffset:dstCur
                       from:src
                     srcLen:srcLen
                  srcOffset:srcOff
                     layout:t.layout
                widthOfLeaf:widthOfLeaf
                  bigEndian:bigEndian];
            continue;
            }

        // The image span to the next field includes any inter-field padding;
        // copy only the leaf's real width so pad bytes never smear.
        NSUInteger srcW = [self irWidthOfField:i inLayout:lay];

        NSUInteger n = MIN(srcW, dstW);
        // Little-endian copy; a narrow source zero-extends into a wider slot.
        for (NSUInteger b = 0; b < n; b++)
            {
            if (srcOff + b >= srcLen)
                break; // short image: tail is zero
            if (dstCur + b >= dstLen)
                break;
            dst[dstCur + b] = src[srcOff + b];
            }
        if (bigEndian && dstW > 1 && dstCur + dstW <= dstLen)
            {
            for (NSUInteger k = 0; k < dstW / 2; k++)
                {
                uint8_t tmp = dst[dstCur + k];
                dst[dstCur + k] = dst[dstCur + dstW - 1 - k];
                dst[dstCur + dstW - 1 - k] = tmp;
                }
            }
        }
    }

+ (NSData*)relay:(NSData*)src
          layout:(XTIRLayout*)layout
     widthOfLeaf:(NSUInteger (^)(XTIRType*))widthOfLeaf
       bigEndian:(BOOL)bigEndian
    {
    if (!layout || !widthOfLeaf)
        return src;

    // The emitted image is the full layout footprint — including the
    // trailing tail pad (which the old per-field sum dropped at top level
    // while including it for NESTED aggregates; with recorded offsets the
    // layout.size is authoritative for both).
    NSUInteger total = layout.size;
    for (XTIRLayoutField* f in layout.fields)
        {
        NSUInteger end = f.byteOffset + [self backendSizeOf:f.type widthOfLeaf:widthOfLeaf];
        if (end > total)
            total = end;
        }
    if (total == 0)
        return src;

    NSMutableData* out = [NSMutableData dataWithLength:total];
    [self relayInto:out.mutableBytes
             dstLen:total
          dstOffset:0
               from:src.bytes
             srcLen:src.length
          srcOffset:0
             layout:layout
        widthOfLeaf:widthOfLeaf
          bigEndian:bigEndian];
    return out;
    }

@end
