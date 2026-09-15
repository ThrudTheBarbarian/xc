// XTArArchive.h — the `ar` container, which is the one thing Mach-O, ELF and
// COFF static libraries genuinely share.
//
// Each writer had its own copy of this loop, differing only in which
// `objectFromData:` it called at the end. Copies of a container parser are the
// shape that drifts: a fix to the long-name member or the padding rule lands in
// one and not the others, and nothing fails until a library happens to use it.
//
// XTElfWriter and XTPEWriter use this. XTMachOWriter still has its own, because
// it parses members in place at absolute offsets into the whole archive rather
// than from member data, so converting it is a re-plumb of a working path with
// no functional gain — worth doing, but not folded into an unrelated change.
// The BSD `#1/<len>` long-name form it needs is implemented here already.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTArArchive : NSObject

// The archive's members in file order, each `@{@"name": NSString, @"data":
// NSData}`. Returns nil if the file is not an `ar` archive at all, which is how
// a caller distinguishes "not an archive" from "an archive with no members".
//
// The symbol-index member (`/`) and the long-name member (`//`) are consumed
// and not returned: members' own symbol tables say what they define, and
// trusting those means never disagreeing with an index that may be stale.
+ (nullable NSArray<NSDictionary*>*)membersOfArchive:(NSString*)path;

// Same, for an archive already in memory.
+ (nullable NSArray<NSDictionary*>*)membersOfArchiveData:(NSData*)d;

@end

NS_ASSUME_NONNULL_END
