// elf-smoke — end-to-end proof of the self-hosted Linux last stage: assemble
// x86-64 with XAX86_64Assembler, wrap with XTElfWriter, write a runnable Linux
// ELF. No Linux tooling involved at any point (no clang, no ld, no libc).
//
//   elf-smoke <out>            exit(42) only — the minimal chain
//   elf-smoke <out> --hello    write(1,"hello from xtc\n",15) then exit(0)
//
// Run the result on a Linux box; `--hello` also exercises data addressing.
#import <Foundation/Foundation.h>
#import "XAX86_64Assembler.h"
#import "XTElfWriter.h"

static NSData* asmLines(NSArray<NSString*>* lines)
    {
    NSMutableData* code = [NSMutableData data];
    for (NSString* l in lines)
        {
        NSError* e = nil;
        XAX86_64Assembler* as = [[XAX86_64Assembler alloc] init];
        NSData* b = [as encodeOne:l error:&e];
        if (!b)
            {
            fprintf(stderr, "elf-smoke: cannot encode '%s': %s\n", l.UTF8String,
                    e ? e.localizedDescription.UTF8String : "?");
            return nil;
            }
        [code appendData:b];
        }
    return code;
    }

int main(int argc, char** argv)
    {
    @autoreleasepool
        {
        if (argc < 2)
            {
            fprintf(stderr, "usage: elf-smoke <out> [--hello]\n");
            return 2;
            }
        BOOL hello = (argc > 2 && strcmp(argv[2], "--hello") == 0);
        NSData* code = nil;

        if (!hello)
            {
            code = asmLines(@[ @"mov rax, 60", // SYS_exit
                               @"mov rdi, 42", // status
                               @"syscall" ]);
            }
        else
            {
            // The message lives right after the code in the same (R+X) segment, so its
            // address is textAddr + codeLen. That length depends on the encoding, which
            // depends on the address — so encode once to measure, then again for real.
            const char* msg = "hello from xtc\n";
            uint64_t msgLen = strlen(msg);
            NSArray* (^prog)(uint64_t) = ^(uint64_t msgAddr) {
              return @[ @"mov rax, 1", // SYS_write
                        @"mov rdi, 1", // fd = stdout
                        [NSString stringWithFormat:@"movabs rsi, %llu", (unsigned long long)msgAddr],
                        [NSString stringWithFormat:@"mov rdx, %llu", (unsigned long long)msgLen],
                        @"syscall",
                        @"mov rax, 60", @"mov rdi, 0", @"syscall" ];
            };
            NSData* probe = asmLines(prog(0));
            if (!probe)
                return 1;
            uint64_t textAddr = [XTElfWriter textAddressWithDataSegment:NO];
            NSMutableData* full = [asmLines(prog(textAddr + probe.length)) mutableCopy];
            if (!full)
                return 1;
            [full appendBytes:msg length:msgLen];
            code = full;
            }
        if (!code)
            return 1;

        NSData* elf = [XTElfWriter staticExecutableFromText:code entryOffset:0 data:nil];
        if (![elf writeToFile:@(argv[1]) atomically:YES])
            {
            fprintf(stderr, "elf-smoke: cannot write '%s'\n", argv[1]);
            return 1;
            }
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755}
                                         ofItemAtPath:@(argv[1])
                                                error:NULL];
        printf("wrote %s (%lu bytes, %lu bytes of code)\n",
               argv[1], (unsigned long)elf.length, (unsigned long)code.length);
        return 0;
        }
    }
