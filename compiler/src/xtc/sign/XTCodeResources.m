//
//  XTCodeResources.m — see the header. The plist is serialised with
//  NSPropertyListXMLFormat_v1_0, which is byte-identical to the CoreFoundation
//  writer codesign uses (verified against tests/ios/bundle-golden). The port
//  (selfhost/link/CodeSign.xc) hand-rolls the same bytes: keys ascending by
//  byte value, tab indent, <data> on its own lines, integer-valued <real>.
//

#import "XTCodeResources.h"
#import "XTCrypto.h"

@implementation XTCodeResources

// The default v2 rule set omits these from files2 (they are sealed elsewhere:
// Info.plist by CD slot 1, PkgInfo is code-adjacent, .DS_Store is junk).
static BOOL omittedFromFiles2(NSString* rel)
    {
    return [rel isEqualToString:@"Info.plist"] || [rel isEqualToString:@"PkgInfo"] || [rel isEqualToString:@".DS_Store"] || [rel hasSuffix:@"/.DS_Store"];
    }

// The constant default resource rules codesign writes for an .app (v1 + v2).
// Reproduced verbatim from the golden; reals are doubles so the writer prints
// them the same way (1000, not 1000.0).
static NSDictionary* defaultRules(void)
    {
    return @{
        @"^.*" : @YES,
        @"^.*\\.lproj/" : @{@"optional" : @YES, @"weight" : @1000.0},
        @"^.*\\.lproj/locversion.plist$" : @{@"omit" : @YES, @"weight" : @1100.0},
        @"^Base\\.lproj/" : @{@"weight" : @1010.0},
        @"^version.plist$" : @YES,
    };
    }

static NSDictionary* defaultRules2(void)
    {
    return @{
        @".*\\.dSYM($|/)" : @{@"weight" : @11.0},
        @"^(.*/)?\\.DS_Store$" : @{@"omit" : @YES, @"weight" : @2000.0},
        @"^.*" : @YES,
        @"^.*\\.lproj/" : @{@"optional" : @YES, @"weight" : @1000.0},
        @"^.*\\.lproj/locversion.plist$" : @{@"omit" : @YES, @"weight" : @1100.0},
        @"^Base\\.lproj/" : @{@"weight" : @1010.0},
        @"^Info\\.plist$" : @{@"omit" : @YES, @"weight" : @20.0},
        @"^PkgInfo$" : @{@"omit" : @YES, @"weight" : @20.0},
        @"^embedded\\.provisionprofile$" : @{@"weight" : @20.0},
        @"^version\\.plist$" : @{@"weight" : @20.0},
    };
    }

+ (nullable NSData*)codeResourcesForBundle:(NSString*)bundleDir
                                 resources:(NSArray<NSString*>*)resources
                                     error:(NSString* _Nullable* _Nullable)err
    {
    NSMutableDictionary* files = [NSMutableDictionary dictionary];
    NSMutableDictionary* files2 = [NSMutableDictionary dictionary];

    for (NSString* rel in resources)
        {
        NSString* path = [bundleDir stringByAppendingPathComponent:rel];
        NSData* data = [NSData dataWithContentsOfFile:path];
        if (!data)
            {
            if (err)
                *err = [NSString stringWithFormat:@"cannot read resource '%@'", path];
            return nil;
            }
        files[rel] = [XTCrypto sha1:data]; // v1: SHA-1 of every file
        if (!omittedFromFiles2(rel))
            files2[rel] = @{@"hash2" : [XTCrypto sha256:data]}; // v2: SHA-256
        }

    NSDictionary* top = @{
        @"files" : files,
        @"files2" : files2,
        @"rules" : defaultRules(),
        @"rules2" : defaultRules2(),
    };

    NSError* e = nil;
    NSData* plist = [NSPropertyListSerialization dataWithPropertyList:top
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:&e];
    if (!plist)
        {
        if (err)
            *err = e.localizedDescription ?: @"plist serialisation failed";
        return nil;
        }
    return plist;
    }

@end
