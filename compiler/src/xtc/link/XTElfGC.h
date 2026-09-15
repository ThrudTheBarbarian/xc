// XTElfGC — link-time dead code AND data elimination for the static x86-64
// link (bug 196 Stages C + D). The selfhost mirror is MergedImage.gcDead in
// selfhost/asm/ElfMerge.xc; the two must stay byte-identical (ldx86-diff).
#import <Foundation/Foundation.h>
#import "XAX86_64Assembler.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTElfGC : NSObject

// Bookkeeping from the merge: every object's text/data range and alignment,
// and every unit boundary (text: every symbol, section and object start; data:
// sized symbols, section and object starts).
- (void)noteObjectText:(uint64_t)ts textEnd:(uint64_t)te
                  data:(uint64_t)ds
               dataEnd:(uint64_t)de
             dataAlign:(uint64_t)da
                 label:(NSString*)label;
- (void)noteTextBound:(uint64_t)off;
- (void)noteDataBound:(uint64_t)off;

// Run the GC in place: text/data are compacted, dead symbols removed, every
// symbol offset and fixup remapped, section-relative fixups rewritten.
- (void)runWithText:(NSMutableData*)text
               data:(NSMutableData*)data
            symbols:(NSMutableDictionary<NSString*, NSNumber*>*)syms
        dataSymbols:(NSMutableSet<NSString*>*)dataSyms
         bssSymbols:(NSArray<NSString*>*)bssSyms
             fixups:(NSMutableArray<XAX86_64Fixup*>*)fixups
        seedTextEnd:(uint64_t)seedTextEnd
        seedDataEnd:(uint64_t)seedDataEnd
              entry:(NSString*)entry;

@end

NS_ASSUME_NONNULL_END
