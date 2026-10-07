// XTDwarfWriter.h — DWARF 4 debug information for an executable xcc linked
//
// What -g produces: a line table (.debug_line) and a compile unit with one
// subprogram per function (.debug_info, .debug_abbrev, .debug_str), so a
// debugger can break on file:line, step by line and name every frame.
// Format-independent: each writer (Mach-O, ELF, PE) asks for the sections and
// places them, with the address its text was given.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTDwarfWriter : NSObject

// The source files `.file <n> "<path>"` named, by number (index 0 unused when
// numbering starts at 1, as `.file` numbering does).
@property(nonatomic, readonly) NSMutableDictionary<NSNumber*, NSString*>* files;

// One row per `.loc`: the text offset it applies from and its file/line/col.
- (void)addRowAtOffset:(uint64_t)offset file:(uint32_t)file line:(uint32_t)line column:(uint32_t)column;
- (void)setFile:(uint32_t)number path:(NSString*)path;

// A frame record set up at `offset` (the instruction after which the frame
// pointer holds the address of the saved {fp, lr} pair): from there the call
// frame is fp + 16. A function without one keeps its return address in the
// link register and the stack pointer where the caller left it.
- (void)addFrameSetupAtOffset:(uint64_t)offset;

// True once any row was recorded: a build without -g has none and gets no
// debug sections.
@property(nonatomic, readonly) BOOL hasRows;

// The sections, for text placed at `textAddress` with `textSize` bytes.
// `functions` maps name -> text offset (each runs to the next one, or to the
// end of the text). `minInsnLength` is 4 on arm64 and 1 on x86-64.
// `frameRegister` is the DWARF number of the frame pointer (29 on arm64, 6 on
// x86-64). Keys: debug_line, debug_info, debug_abbrev, debug_str, debug_frame.
- (NSDictionary<NSString*, NSData*>*)sectionsForTextAddress:(uint64_t)textAddress
                                                   textSize:(uint64_t)textSize
                                                  functions:(NSDictionary<NSString*, NSNumber*>*)functions
                                              minInsnLength:(uint8_t)minInsnLength
                                              frameRegister:(uint8_t)frameRegister;

// The debug information of the program being assembled, if it has any: the
// assembler records it here and the writer that places the text reads it.
+ (nullable XTDwarfWriter*)pending;
+ (void)setPending:(nullable XTDwarfWriter*)writer;

@end

NS_ASSUME_NONNULL_END
