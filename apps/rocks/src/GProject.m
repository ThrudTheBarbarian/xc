// GProject.m — see GProject.h.

#import "GProject.h"

static NSDictionary* cwDict(GColorWord c)
    {
    return @{@"border" : @(c.border),
             @"text" : @(c.text),
             @"replace" : @(c.replace),
             @"pattern" : @(c.pattern),
             @"inside" : @(c.inside)};
    }
static GColorWord cwFrom(NSDictionary* d)
    {
    GColorWord c = gcw_default();
    if (!d)
        return c;
    c.border = [d[@"border"] intValue];
    c.text = [d[@"text"] intValue];
    c.replace = [d[@"replace"] boolValue];
    c.pattern = [d[@"pattern"] intValue];
    c.inside = [d[@"inside"] intValue];
    return c;
    }
static NSString* b64(NSData* d)
    {
    return d ? [d base64EncodedStringWithOptions:0] : nil;
    }
static NSData* unb64(NSString* s)
    {
    return s ? [[NSData alloc] initWithBase64EncodedString:s options:0] : nil;
    }

static NSArray* freeImagesToArray(GResource* r)
    {
    NSMutableArray* a = [NSMutableArray array];
    for (GBitblk* bb in r.freeImages)
        [a addObject:@{@"data" : b64(bb.data) ?: @"",
                       @"wb" : @(bb.wb),
                       @"hl" : @(bb.hl),
                       @"x" : @(bb.x),
                       @"y" : @(bb.y),
                       @"color" : @(bb.color)}];
    return a;
    }

static NSDictionary* objToDict(GObject* o)
    {
    NSMutableDictionary* m = [NSMutableDictionary dictionary];
    m[@"type"] = @(o.type);
    m[@"flags"] = @(o.flags);
    m[@"state"] = @(o.state);
    if (o.extType)
        m[@"extType"] = @(o.extType);
    if (o.legacyExtType)
        m[@"legacyExtType"] = @(o.legacyExtType);
    m[@"x"] = @(o.x);
    m[@"y"] = @(o.y);
    m[@"w"] = @(o.w);
    m[@"h"] = @(o.h);
    if (o.text)
        m[@"text"] = o.text;
    if (o.name.length)
        m[@"name"] = o.name;
    if (o.ted)
        {
        m[@"ted"] = @{@"text" : o.ted.text ?: @"",
                      @"tmplt" : o.ted.tmplt ?: @"",
                      @"valid" : o.ted.valid ?: @"",
                      @"font" : @(o.ted.font),
                      @"fontId" : @(o.ted.fontId),
                      @"just" : @(o.ted.just),
                      @"color" : cwDict(o.ted.color),
                      @"fontsize" : @(o.ted.fontsize),
                      @"thickness" : @(o.ted.thickness)};
        }
    if (o.box)
        {
        m[@"box"] = @{@"character" : @(o.box.character),
                      @"thickness" : @(o.box.thickness),
                      @"color" : cwDict(o.box.color)};
        }
    if (o.bitblk)
        {
        m[@"bitblk"] = @{@"data" : b64(o.bitblk.data) ?: @"",
                         @"wb" : @(o.bitblk.wb),
                         @"hl" : @(o.bitblk.hl),
                         @"x" : @(o.bitblk.x),
                         @"y" : @(o.bitblk.y),
                         @"color" : @(o.bitblk.color)};
        }
    if (o.icon)
        {
        NSMutableDictionary* ic = [NSMutableDictionary dictionary];
        ic[@"isColor"] = @(o.icon.isColor);
        ic[@"label"] = o.icon.label ?: @"";
        if (o.icon.pam)
            ic[@"pam"] = b64(o.icon.pam);
        if (o.icon.selPam)
            ic[@"selPam"] = b64(o.icon.selPam);
        if (o.icon.ciconRaw)
            ic[@"ciconRaw"] = b64(o.icon.ciconRaw);
        if (o.icon.externalPath)
            ic[@"externalPath"] = o.icon.externalPath;
        if (o.icon.monoData)
            ic[@"monoData"] = b64(o.icon.monoData);
        if (o.icon.monoMask)
            ic[@"monoMask"] = b64(o.icon.monoMask);
        ic[@"iconChar"] = @(o.icon.iconChar);
        ic[@"charX"] = @(o.icon.charX);
        ic[@"charY"] = @(o.icon.charY);
        ic[@"textX"] = @(o.icon.textX);
        ic[@"textY"] = @(o.icon.textY);
        ic[@"textW"] = @(o.icon.textW);
        ic[@"textH"] = @(o.icon.textH);
        ic[@"iconX"] = @(o.icon.iconX);
        ic[@"iconY"] = @(o.icon.iconY);
        ic[@"iconW"] = @(o.icon.iconW);
        ic[@"iconH"] = @(o.icon.iconH);
        m[@"icon"] = ic;
        }
    if (o.children.count)
        {
        NSMutableArray* kids = [NSMutableArray array];
        for (GObject* c in o.children)
            [kids addObject:objToDict(c)];
        m[@"children"] = kids;
        }
    return m;
    }

static GObject* objFromDict(NSDictionary* d)
    {
    GObject* o = [GObject new];
    o.type = (GObType)[d[@"type"] intValue];
    o.extType = (uint8_t)[d[@"extType"] intValue];
    o.legacyExtType = (uint8_t)[d[@"legacyExtType"] intValue];
    o.flags = (GFlags)[d[@"flags"] intValue];
    o.state = (GState)[d[@"state"] intValue];
    o.x = [d[@"x"] intValue];
    o.y = [d[@"y"] intValue];
    o.w = [d[@"w"] intValue];
    o.h = [d[@"h"] intValue];
    o.text = d[@"text"];
    o.name = d[@"name"];
    NSDictionary* td = d[@"ted"];
    if (td)
        {
        GTedinfo* t = [GTedinfo new];
        t.text = td[@"text"] ?: @"";
        t.tmplt = td[@"tmplt"] ?: @"";
        t.valid = td[@"valid"] ?: @"";
        t.font = [td[@"font"] intValue];
        t.fontId = [td[@"fontId"] intValue];
        t.just = [td[@"just"] intValue];
        t.color = cwFrom(td[@"color"]);
        t.fontsize = [td[@"fontsize"] intValue];
        t.thickness = [td[@"thickness"] intValue];
        o.ted = t;
        }
    NSDictionary* bd = d[@"box"];
    if (bd)
        {
        GBox* b = [GBox new];
        b.character = (uint8_t)[bd[@"character"] intValue];
        b.thickness = [bd[@"thickness"] intValue];
        b.color = cwFrom(bd[@"color"]);
        o.box = b;
        }
    NSDictionary* bbd = d[@"bitblk"];
    if (bbd)
        {
        GBitblk* bb = [GBitblk new];
        bb.data = unb64(bbd[@"data"]);
        bb.wb = [bbd[@"wb"] intValue];
        bb.hl = [bbd[@"hl"] intValue];
        bb.x = [bbd[@"x"] intValue];
        bb.y = [bbd[@"y"] intValue];
        bb.color = [bbd[@"color"] intValue];
        o.bitblk = bb;
        }
    NSDictionary* id_ = d[@"icon"];
    if (id_)
        {
        GIcon* ic = [GIcon new];
        ic.isColor = [id_[@"isColor"] boolValue];
        ic.label = id_[@"label"] ?: @"";
        ic.pam = unb64(id_[@"pam"]);
        ic.externalPath = id_[@"externalPath"];
        ic.selPam = unb64(id_[@"selPam"]);
        ic.ciconRaw = unb64(id_[@"ciconRaw"]);
        ic.monoData = unb64(id_[@"monoData"]);
        ic.monoMask = unb64(id_[@"monoMask"]);
        ic.iconChar = [id_[@"iconChar"] intValue];
        ic.charX = [id_[@"charX"] intValue];
        ic.charY = [id_[@"charY"] intValue];
        ic.textX = [id_[@"textX"] intValue];
        ic.textY = [id_[@"textY"] intValue];
        ic.textW = [id_[@"textW"] intValue];
        ic.textH = [id_[@"textH"] intValue];
        ic.iconX = [id_[@"iconX"] intValue];
        ic.iconY = [id_[@"iconY"] intValue];
        ic.iconW = [id_[@"iconW"] intValue];
        ic.iconH = [id_[@"iconH"] intValue];
        o.icon = ic;
        }
    for (NSDictionary* cd in d[@"children"])
        [o.children addObject:objFromDict(cd)];
    return o;
    }

NSDictionary* GResourceToDictionary(GResource* r)
    {
    NSMutableArray* trees = [NSMutableArray array];
    for (GTree* t in r.trees)
        {
        [trees addObject:@{@"name" : t.name ?: @"",
                           @"kind" : @(t.kind),
                           @"root" : objToDict(t.root)}];
        }
    return @{@"version" : @1,
             @"bigEndian" : @(r.bigEndian),
             @"freeStrings" : r.freeStrings ?: @[],
             @"freeImages" : freeImagesToArray(r),
             @"packedCoords" : @(r.packedCoords),
             @"embedIcons" : @(r.embedIcons),
             @"charWidth" : @(r.charWidth),
             @"charHeight" : @(r.charHeight),
             @"trees" : trees};
    }

GResource* GResourceFromDictionary(NSDictionary* d)
    {
    if (![d isKindOfClass:[NSDictionary class]])
        return nil;
    GResource* r = [GResource new];
    r.bigEndian = d[@"bigEndian"] ? [d[@"bigEndian"] boolValue] : YES;
    r.packedCoords = [d[@"packedCoords"] boolValue];
    r.embedIcons = d[@"embedIcons"] ? [d[@"embedIcons"] boolValue] : YES;
    r.charWidth = d[@"charWidth"] ? [d[@"charWidth"] intValue] : 8;
    r.charHeight = d[@"charHeight"] ? [d[@"charHeight"] intValue] : 16;
    r.freeStrings = [(d[@"freeStrings"] ?: @[]) mutableCopy];
    r.freeImages = [NSMutableArray array];
    for (NSDictionary* bd in d[@"freeImages"])
        {
        GBitblk* bb = [GBitblk new];
        bb.data = unb64(bd[@"data"]);
        bb.wb = [bd[@"wb"] intValue];
        bb.hl = [bd[@"hl"] intValue];
        bb.x = [bd[@"x"] intValue];
        bb.y = [bd[@"y"] intValue];
        bb.color = [bd[@"color"] intValue];
        [r.freeImages addObject:bb];
        }
    r.trees = [NSMutableArray array];
    for (NSDictionary* td in d[@"trees"])
        {
        GTree* t = [GTree new];
        t.name = td[@"name"] ?: @"TREE";
        t.kind = (GTreeKind)[td[@"kind"] intValue];
        t.root = objFromDict(td[@"root"]);
        [r.trees addObject:t];
        }
    return r.trees.count ? r : nil;
    }

NSData* GResourceToJSON(GResource* r)
    {
    return [NSJSONSerialization dataWithJSONObject:GResourceToDictionary(r)
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
    }
GResource* GResourceFromJSON(NSData* json)
    {
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    return obj ? GResourceFromDictionary(obj) : nil;
    }
