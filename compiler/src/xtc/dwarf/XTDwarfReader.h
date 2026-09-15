#import <Foundation/Foundation.h>
#import "XTDwarfInterface.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString* const XTDwarfErrorDomain;

/****************************************************************************\
|* Reads a shared library's self-description — its `.dynsym` export set and
|* its DWARF type/signature information — and synthesises an
|* XTDwarfInterface the front end can import. Arch-neutral: it parses ELF
|* (ELFCLASS32/64, either endianness) and a restricted DWARF 2–5 subset
|* (the profile xtc itself emits; see docs dwarf-subset.md).
|*
|* The cardinal rule (library-imports.md §3): struct layouts are taken
|* VERBATIM from the DWARF — DW_AT_data_member_location per member and
|* DW_AT_byte_size for the whole — never re-derived by xtc's own packing.
|* C padding is reconstructed as explicit pad bytes so the imported type is
|* byte-identical by construction.
\****************************************************************************/
@interface XTDwarfReader : NSObject

/****************************************************************************\
|* Read the importable interface from a `.so` on disk.
|* @param path   Path to an ELF shared object (must carry DWARF — i.e. a
|*               Debug/ build, not a stripped runtime build).
|* @param error  On failure, populated with an XTDwarfErrorDomain error.
|* @return The interface, or nil on a malformed / debug-info-free file.
\****************************************************************************/
+ (nullable XTDwarfInterface*)readInterfaceFromPath:(NSString*)path
                                              error:(NSError* _Nullable* _Nullable)error;

/****************************************************************************\
|* As above, but with the target's native pointer width (4 on arm9/A32, 8
|* on a 64-bit host, 2 on the 6502 front end). Struct padding is
|* reconstructed so the field sequence reproduces the DWARF offsets when
|* tight-packed at the BACKEND's native widths — pointers in particular are
|* re-sized per backend, so a pointer-followed-by-member struct only lays
|* out byte-identically if pads are computed at the native pointer width.
|* Default (the no-width method) is 2.
\****************************************************************************/
+ (nullable XTDwarfInterface*)readInterfaceFromPath:(NSString*)path
                                 targetPointerWidth:(NSUInteger)ptrWidth
                                              error:(NSError* _Nullable* _Nullable)error;

/****************************************************************************\
|* As above, reading from an in-memory ELF image (used by the tests).
\****************************************************************************/
+ (nullable XTDwarfInterface*)readInterfaceFromData:(NSData*)data
                                               name:(NSString*)displayName
                                 targetPointerWidth:(NSUInteger)ptrWidth
                                              error:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
