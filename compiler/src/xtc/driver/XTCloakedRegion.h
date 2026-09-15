#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* One cloaked-code region — a slice of the bank window where `:cloaked`
|* code can live. Each region carries a target-specific bank descriptor:
|*
|*   bankIndex == -1   "banking off" (xe-family: PORTB bit-4 set,
|*                     library RAM at $4000-$7FFF visible). The
|*                     historical sole cloaked mode.
|*   bankIndex >=  0   numbered bank inside the bank window. xe-family
|*                     deposits the bits into PORTB; xt would write
|*                     `$82` (not currently exposed).
|*
|* `regionId` is a layout-author-chosen string used by the source
|* annotation `:cloaked(<id>)` to pin a decl to a specific region. The
|* legacy single-`[cloaked]` form auto-generates id `lib` with
|* bankIndex `-1` to keep older layouts compiling unchanged.
\****************************************************************************/
@interface XTCloakedRegion : NSObject

@property(nonatomic) uint16_t start;
@property(nonatomic) uint16_t end;  // inclusive
@property(nonatomic) int bankIndex; // -1 = banking off, else 0..N
/****************************************************************************\
|* Inclusive upper bound of a bank range, used during layout parsing only.
|* `bank = N-M` in the .lnk sets bankIndex=N and bankIndexEnd=M; the
|* parser commits the block by expanding into M-N+1 concrete regions
|* (each with its own bankIndex and id derived from the `<n>` placeholder
|* in the id template). For non-range and post-expansion regions,
|* bankIndexEnd == bankIndex.
\****************************************************************************/
@property(nonatomic) int bankIndexEnd;
@property(nonatomic, copy) NSString* regionId;

+ (instancetype)regionWithStart:(uint16_t)start
                            end:(uint16_t)end
                      bankIndex:(int)bankIndex
                       regionId:(NSString*)regionId;

@end

NS_ASSUME_NONNULL_END
