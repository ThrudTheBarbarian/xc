// Standalone driver: assemble argv[1] (.s) -> emit executable argv[2].
#import "XAArm64Assembler.h"
#import "XTMachOWriter.h"
int main(int argc, char** argv)
    {
    @autoreleasepool
        {
        if (argc < 3)
            {
            fprintf(stderr, "usage: macho-smoke in.s out\n");
            return 2;
            }
        NSString* src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:NULL];
        XAArm64Assembler* as = [XAArm64Assembler new];
        NSError* e = nil;
        NSData* text = [as assemble:src error:&e];
        if (!text)
            {
            fprintf(stderr, "asm: %s\n", e.localizedDescription.UTF8String);
            return 1;
            }
        NSNumber* entry = as.symbols[@"_xtc_start"] ?: as.symbols[@"_main"];
        NSData* m = [XTMachOWriter executableFromText:text
                                          entryOffset:entry ? entry.unsignedLongLongValue : 0
                                              symbols:as.symbols
                                                 data:as.data
                                          dataSymbols:as.dataSymbols
                                               fixups:as.fixups];
        [m writeToFile:@(argv[2]) atomically:YES];
        return 0;
        }
    }
