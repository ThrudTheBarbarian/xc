// XTIRSupport.m
#import "XTIRSupport.h"

#pragma mark - XTIRCallConv

@implementation XTIRCallConv

- (instancetype)initWithKind:(XTIRCallConvKind)kind
                     hwStack:(BOOL)hwStack
                       naked:(BOOL)naked
    {
    self = [super init];
    if (self)
        {
        _kind = kind;
        _hwStack = hwStack;
        _naked = naked;
        }
    return self;
    }

+ (instancetype)standard
    {
    return [(XTIRCallConv*)[self alloc] initWithKind:XTIRCallConvStandard hwStack:YES naked:NO];
    }

+ (instancetype)cloaked
    {
    return [(XTIRCallConv*)[self alloc] initWithKind:XTIRCallConvCloaked hwStack:NO naked:NO];
    }

+ (instancetype)banked
    {
    return [(XTIRCallConv*)[self alloc] initWithKind:XTIRCallConvBanked hwStack:YES naked:NO];
    }

+ (instancetype)inlineConv
    {
    return [(XTIRCallConv*)[self alloc] initWithKind:XTIRCallConvInline hwStack:NO naked:NO];
    }

+ (instancetype)runtimeHelper
    {
    return [(XTIRCallConv*)[self alloc] initWithKind:XTIRCallConvRuntimeHelper hwStack:YES naked:NO];
    }

- (id)copyWithZone:(nullable NSZone*)zone
    {
    return [[XTIRCallConv alloc] initWithKind:self.kind hwStack:self.hwStack naked:self.naked];
    }

- (BOOL)isEqual:(nullable id)object
    {
    if (![object isKindOfClass:[XTIRCallConv class]])
        return NO;
    XTIRCallConv* other = (XTIRCallConv*)object;
    return self.kind == other.kind && self.hwStack == other.hwStack && self.naked == other.naked;
    }

- (NSUInteger)hash
    {
    return ((NSUInteger)self.kind << 2) | (self.hwStack ? 2 : 0) | (self.naked ? 1 : 0);
    }

@end

#pragma mark - XTIRDbgLoc

@implementation XTIRDbgLoc

- (instancetype)initWithFileId:(uint32_t)fileId
                          line:(uint32_t)line
                        column:(uint32_t)column
    {
    self = [super init];
    if (self)
        {
        _fileId = fileId;
        _line = line;
        _column = column;
        }
    return self;
    }

static XTIRDbgLoc* gCurrentDbgLoc = nil;
static NSMutableArray<NSString*>* gDbgFiles = nil;

+ (nullable XTIRDbgLoc*)current
    {
    return gCurrentDbgLoc;
    }

+ (void)setCurrent:(nullable XTIRDbgLoc*)loc
    {
    gCurrentDbgLoc = loc;
    }

+ (uint32_t)fileIdForPath:(NSString*)path
    {
    if (gDbgFiles == nil)
        gDbgFiles = [NSMutableArray array];
    NSUInteger i = [gDbgFiles indexOfObject:path];
    if (i != NSNotFound)
        return (uint32_t)i;
    [gDbgFiles addObject:path];
    return (uint32_t)(gDbgFiles.count - 1);
    }

+ (void)setPath:(NSString*)path forFileId:(uint32_t)fileId
    {
    if (gDbgFiles == nil)
        gDbgFiles = [NSMutableArray array];
    while (gDbgFiles.count <= fileId)
        [gDbgFiles addObject:@""];
    gDbgFiles[fileId] = path;
    }

+ (NSArray<NSString*>*)files
    {
    return gDbgFiles ?: @[];
    }

+ (NSString*)canonicalPath:(NSString*)path
    {
    if (path.length == 0)
        return path;
    if (!path.isAbsolutePath)
        path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    return path.stringByStandardizingPath;
    }

+ (void)resetFiles
    {
    gDbgFiles = nil;
    gCurrentDbgLoc = nil;
    }

@end
