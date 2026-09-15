#import "XTApkWriter.h"

// ── little-endian emitters ────────────────────────────────────────────────
static void w8(NSMutableData* d, uint8_t v)
    {
    [d appendBytes:&v length:1];
    }
static void w16(NSMutableData* d, uint16_t v)
    {
    for (int i = 0; i < 2; i++)
        w8(d, (uint8_t)(v >> (8 * i)));
    }
static void w32(NSMutableData* d, uint32_t v)
    {
    for (int i = 0; i < 4; i++)
        w8(d, (uint8_t)(v >> (8 * i)));
    }

// ── binary XML ────────────────────────────────────────────────────────────
//
// Chunk types. Every chunk is {u16 type, u16 headerSize, u32 size}, and the
// size covers the header, so a reader can skip a chunk it does not know.
enum
    {
    RES_XML = 0x0003,
    RES_STRING_POOL = 0x0001,
    RES_XML_RESOURCE_MAP = 0x0180,
    RES_XML_START_NS = 0x0100,
    RES_XML_END_NS = 0x0101,
    RES_XML_START_ELEM = 0x0102,
    RES_XML_END_ELEM = 0x0103
    };
// Res_value dataTypes.
enum
    {
    TYPE_STRING = 0x03,
    TYPE_INT_DEC = 0x10,
    TYPE_INT_BOOLEAN = 0x12
    };

#define ANDROID_NS @"http://schemas.android.com/apk/res/android"
#define NO_ENTRY 0xFFFFFFFFu

// The framework attributes this manifest uses, in ASCENDING resource-id order.
// That order is not cosmetic: the resource-map chunk is positional, so pool
// string i must be the name of resource id map[i]. Get it wrong and every
// attribute silently binds to the wrong framework attribute.
static NSArray<NSString*>* attrNames(void)
    {
    return @[ @"label", @"name", @"hasCode", @"exported", @"value",
              @"minSdkVersion", @"targetSdkVersion", @"extractNativeLibs" ];
    }
static NSArray<NSNumber*>* attrIds(void)
    {
    return @[ @0x01010001, @0x01010003, @0x0101000c, @0x01010010, @0x01010024,
              @0x0101020c, @0x01010270, @0x010104ea ];
    }

// A string pool being built: the attribute names occupy the low indices, and
// everything else is interned behind them in first-use order.
@interface XTApkPool : NSObject
@property(nonatomic) NSMutableArray<NSString*>* strings;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* index;
@end

@implementation XTApkPool
- (instancetype)init
    {
    if ((self = [super init]))
        {
        _strings = [NSMutableArray array];
        _index = [NSMutableDictionary dictionary];
        for (NSString* a in attrNames())
            [self intern:a];
        }
    return self;
    }
- (uint32_t)intern:(NSString*)s
    {
    NSNumber* have = self.index[s];
    if (have)
        return have.unsignedIntValue;
    uint32_t at = (uint32_t)self.strings.count;
    self.index[s] = @(at);
    [self.strings addObject:s];
    return at;
    }
@end

// UTF-16 pool. Each string is {u16 charCount, chars…, u16 0}; the data area is
// padded to 4 so the next chunk starts aligned.
static NSData* poolChunk(XTApkPool* pool)
    {
    NSMutableData* offsets = [NSMutableData data];
    NSMutableData* body = [NSMutableData data];
    for (NSString* s in pool.strings)
        {
        w32(offsets, (uint32_t)body.length);
        NSUInteger n = s.length; // UTF-16 code units
        w16(body, (uint16_t)n);
        unichar buf[n > 0 ? n : 1];
        [s getCharacters:buf range:NSMakeRange(0, n)];
        for (NSUInteger i = 0; i < n; i++)
            w16(body, buf[i]);
        w16(body, 0);
        }
    while (body.length % 4)
        w8(body, 0);
    uint32_t headerSize = 28;
    uint32_t stringsStart = headerSize + (uint32_t)offsets.length;
    NSMutableData* out = [NSMutableData data];
    w16(out, RES_STRING_POOL);
    w16(out, (uint16_t)headerSize);
    w32(out, (uint32_t)(headerSize + offsets.length + body.length));
    w32(out, (uint32_t)pool.strings.count);
    w32(out, 0); // styleCount
    w32(out, 0); // flags: UTF-16, unsorted
    w32(out, stringsStart);
    w32(out, 0); // stylesStart
    [out appendData:offsets];
    [out appendData:body];
    return out;
    }

// One attribute of a START_ELEM: 20 bytes, ending in a Res_value.
static void writeAttr(NSMutableData* d, uint32_t ns, uint32_t name,
                      uint32_t rawValue, uint8_t type, uint32_t data)
    {
    w32(d, ns);
    w32(d, name);
    w32(d, rawValue);
    w16(d, 8);
    w8(d, 0);
    w8(d, type);
    w32(d, data);
    }

static void writeStartElem(NSMutableData* out, uint32_t nsIdx, uint32_t nameIdx,
                           NSData* attrs, NSUInteger attrCount)
    {
    w16(out, RES_XML_START_ELEM);
    w16(out, 16);
    w32(out, (uint32_t)(36 + attrs.length));
    w32(out, 0);        // lineNumber
    w32(out, NO_ENTRY); // comment
    w32(out, nsIdx);
    w32(out, nameIdx);
    w16(out, 20); // attributeStart
    w16(out, 20); // attributeSize
    w16(out, (uint16_t)attrCount);
    w16(out, 0);
    w16(out, 0);
    w16(out, 0); // id / class / style index
    [out appendData:attrs];
    }

static void writeEndElem(NSMutableData* out, uint32_t nsIdx, uint32_t nameIdx)
    {
    w16(out, RES_XML_END_ELEM);
    w16(out, 16);
    w32(out, 24);
    w32(out, 0);
    w32(out, NO_ENTRY);
    w32(out, nsIdx);
    w32(out, nameIdx);
    }

@implementation XTApkWriter

+ (uint32_t)crc32:(NSData*)data
    {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      for (uint32_t i = 0; i < 256; i++)
          {
          uint32_t c = i;
          for (int k = 0; k < 8; k++)
              c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
          table[i] = c;
          }
    });
    const uint8_t* p = data.bytes;
    uint32_t c = 0xFFFFFFFFu;
    for (NSUInteger i = 0; i < data.length; i++)
        c = table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
    }

+ (NSData*)binaryManifestForPackage:(NSString*)pkg
                            libName:(NSString*)libName
                              label:(NSString*)label
                             minSdk:(int)minSdk
                          targetSdk:(int)targetSdk
                            hasCode:(BOOL)hasCode
    {
    XTApkPool* p = [[XTApkPool alloc] init];
    // Interned up front so the pool reads in a stable order regardless of the
    // order the elements below happen to need them.
    uint32_t sManifest = [p intern:@"manifest"];
    uint32_t sUsesSdk = [p intern:@"uses-sdk"];
    uint32_t sApp = [p intern:@"application"];
    uint32_t sActivity = [p intern:@"activity"];
    uint32_t sMeta = [p intern:@"meta-data"];
    uint32_t sFilter = [p intern:@"intent-filter"];
    uint32_t sAction = [p intern:@"action"];
    uint32_t sCategory = [p intern:@"category"];
    uint32_t sAndroid = [p intern:@"android"];
    uint32_t sNsUri = [p intern:ANDROID_NS];
    uint32_t sPackage = [p intern:@"package"];
    uint32_t sPkg = [p intern:pkg];
    uint32_t sLabel = [p intern:label];
    uint32_t sLib = [p intern:libName];
    uint32_t sNative = [p intern:@"android.app.NativeActivity"];
    uint32_t sLibName = [p intern:@"android.app.lib_name"];
    uint32_t sMain = [p intern:@"android.intent.action.MAIN"];
    uint32_t sLauncher = [p intern:@"android.intent.category.LAUNCHER"];

    NSDictionary<NSString*, NSNumber*>* A = p.index;
    uint32_t aLabel = A[@"label"].unsignedIntValue;
    uint32_t aName = A[@"name"].unsignedIntValue;
    uint32_t aHasCode = A[@"hasCode"].unsignedIntValue;
    uint32_t aExported = A[@"exported"].unsignedIntValue;
    uint32_t aValue = A[@"value"].unsignedIntValue;
    uint32_t aMinSdk = A[@"minSdkVersion"].unsignedIntValue;
    uint32_t aTgtSdk = A[@"targetSdkVersion"].unsignedIntValue;
    uint32_t aExtract = A[@"extractNativeLibs"].unsignedIntValue;

    NSMutableData* body = [NSMutableData data];

    // START_NS android -> the framework URI. Everything namespaced below names
    // the URI by pool index, not the prefix.
    w16(body, RES_XML_START_NS);
    w16(body, 16);
    w32(body, 24);
    w32(body, 0);
    w32(body, NO_ENTRY);
    w32(body, sAndroid);
    // <manifest package="…">
    w32(body, sNsUri);

        {
        NSMutableData* a = [NSMutableData data];
        writeAttr(a, NO_ENTRY, sPackage, sPkg, TYPE_STRING, sPkg);
        writeStartElem(body, NO_ENTRY, sManifest, a, 1);
        // <uses-sdk android:minSdkVersion … targetSdkVersion …/>
        }
        {
        NSMutableData* a = [NSMutableData data];
        writeAttr(a, sNsUri, aMinSdk, NO_ENTRY, TYPE_INT_DEC, (uint32_t)minSdk);
        writeAttr(a, sNsUri, aTgtSdk, NO_ENTRY, TYPE_INT_DEC, (uint32_t)targetSdk);
        writeStartElem(body, NO_ENTRY, sUsesSdk, a, 2);
        writeEndElem(body, NO_ENTRY, sUsesSdk);
        // <application android:label … hasCode=false extractNativeLibs=true>
        }
        {
        NSMutableData* a = [NSMutableData data];
        writeAttr(a, sNsUri, aLabel, sLabel, TYPE_STRING, sLabel);
        writeAttr(a, sNsUri, aHasCode, NO_ENTRY, TYPE_INT_BOOLEAN,
                  hasCode ? 0xFFFFFFFFu : 0);
        writeAttr(a, sNsUri, aExtract, NO_ENTRY, TYPE_INT_BOOLEAN, 0xFFFFFFFFu);
        writeStartElem(body, NO_ENTRY, sApp, a, 3);
        // <activity android:label … name=NativeActivity exported=true>
        }
        {
        NSMutableData* a = [NSMutableData data];
        writeAttr(a, sNsUri, aLabel, sLabel, TYPE_STRING, sLabel);
        writeAttr(a, sNsUri, aName, sNative, TYPE_STRING, sNative);
        writeAttr(a, sNsUri, aExported, NO_ENTRY, TYPE_INT_BOOLEAN, 0xFFFFFFFFu);
        writeStartElem(body, NO_ENTRY, sActivity, a, 3);
        // <meta-data android:name="android.app.lib_name" android:value=lib/>
        }
        {
        NSMutableData* a = [NSMutableData data];
        writeAttr(a, sNsUri, aName, sLibName, TYPE_STRING, sLibName);
        writeAttr(a, sNsUri, aValue, sLib, TYPE_STRING, sLib);
        writeStartElem(body, NO_ENTRY, sMeta, a, 2);
        writeEndElem(body, NO_ENTRY, sMeta);
        // <intent-filter><action MAIN/><category LAUNCHER/></intent-filter>
        }
        {
        writeStartElem(body, NO_ENTRY, sFilter, [NSData data], 0);
        NSMutableData* a = [NSMutableData data];
        writeAttr(a, sNsUri, aName, sMain, TYPE_STRING, sMain);
        writeStartElem(body, NO_ENTRY, sAction, a, 1);
        writeEndElem(body, NO_ENTRY, sAction);
        NSMutableData* c = [NSMutableData data];
        writeAttr(c, sNsUri, aName, sLauncher, TYPE_STRING, sLauncher);
        writeStartElem(body, NO_ENTRY, sCategory, c, 1);
        writeEndElem(body, NO_ENTRY, sCategory);
        writeEndElem(body, NO_ENTRY, sFilter);
        }
    writeEndElem(body, NO_ENTRY, sActivity);
    writeEndElem(body, NO_ENTRY, sApp);
    writeEndElem(body, NO_ENTRY, sManifest);
    w16(body, RES_XML_END_NS);
    w16(body, 16);
    w32(body, 24);
    w32(body, 0);
    w32(body, NO_ENTRY);
    w32(body, sAndroid);
    w32(body, sNsUri);

    // The pool is only final once every string has been interned, so it is
    // built last and prepended.
    NSData* pool = poolChunk(p);
    NSMutableData* map = [NSMutableData data];
    w16(map, RES_XML_RESOURCE_MAP);
    w16(map, 8);
    w32(map, (uint32_t)(8 + attrIds().count * 4));
    for (NSNumber* n in attrIds())
        w32(map, n.unsignedIntValue);

    NSMutableData* out = [NSMutableData data];
    w16(out, RES_XML);
    w16(out, 8);
    w32(out, (uint32_t)(8 + pool.length + map.length + body.length));
    [out appendData:pool];
    [out appendData:map];
    [out appendData:body];
    return out;
    }

+ (NSData*)zipWithEntries:(NSArray<NSDictionary*>*)entries
                alignment:(NSUInteger)alignment
              alignSuffix:(NSString*)alignSuffix
    {
    NSMutableData* out = [NSMutableData data];
    NSMutableData* central = [NSMutableData data];
    NSUInteger count = 0;

    for (NSDictionary* e in entries)
        {
        NSString* name = e[@"name"];
        NSData* data = e[@"data"];
        NSData* nameBytes = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = [self crc32:data];
        NSUInteger localOff = out.length;

        // Pad the EXTRA field so the entry's DATA lands on a boundary. That is
        // what zipalign does after the fact; doing it while writing means the
        // file never has to be rewritten.
        //
        // A library the loader mmaps needs the FULL page alignment; everything
        // else still gets 4, which is what `zipalign -c -p 4` checks and what
        // every other entry was silently missing — our packages have always
        // failed that check on AndroidManifest.xml and classes.dex, since only
        // the suffix match was aligned at all. Nothing refused to install over
        // it, but a gate script that runs zipalign -c reads it as a broken
        // package, and `resources.arsc` (if this writer ever emits one) is a
        // case R+ genuinely refuses — see the note in the header.
        NSUInteger want = (alignSuffix && alignment > 1 && [name hasSuffix:alignSuffix])
                              ? alignment
                              : 4;
        NSUInteger extraLen = 0;
        if (want > 1)
            {
            NSUInteger dataAt = localOff + 30 + nameBytes.length;
            extraLen = (want - (dataAt % want)) % want;
            }

        w32(out, 0x04034b50); // local file header
        w16(out, 20);         // version needed
        w16(out, 0);          // flags
        w16(out, 0);          // method 0 = stored
        w16(out, 0);
        w16(out, 0); // mtime/mdate fixed, so two
                     //   builds of one input give
                     //   the same file
        w32(out, crc);
        w32(out, (uint32_t)data.length);
        w32(out, (uint32_t)data.length);
        w16(out, (uint16_t)nameBytes.length);
        w16(out, (uint16_t)extraLen);
        [out appendData:nameBytes];
        for (NSUInteger i = 0; i < extraLen; i++)
            w8(out, 0);
        [out appendData:data];

        w32(central, 0x02014b50); // central directory entry
        w16(central, 20);
        w16(central, 20);
        w16(central, 0);
        w16(central, 0);
        w16(central, 0);
        w16(central, 0);
        w32(central, crc);
        w32(central, (uint32_t)data.length);
        w32(central, (uint32_t)data.length);
        w16(central, (uint16_t)nameBytes.length);
        w16(central, 0); // extra (central copy)
        w16(central, 0); // comment
        w16(central, 0); // disk
        w16(central, 0); // internal attrs
        w32(central, 0); // external attrs
        w32(central, (uint32_t)localOff);
        [central appendData:nameBytes];
        count++;
        }

    NSUInteger centralOff = out.length;
    [out appendData:central];
    w32(out, 0x06054b50); // end of central directory
    w16(out, 0);
    w16(out, 0);
    w16(out, (uint16_t)count);
    w16(out, (uint16_t)count);
    w32(out, (uint32_t)central.length);
    w32(out, (uint32_t)centralOff);
    w16(out, 0); // comment length
    return out;
    }

@end
