// rockscli.m — headless resource compiler.
//
//   rockscli app.gemproj -o build/app --emit h,c
//   rockscli app.gemproj -o build/app --emit xt
//   rockscli legacy.rsc  -o out/legacy --emit h,c,rsc
//   rockscli --list app.rsc
//
// Reads a Rocks project (.gemproj) or a GEM resource (.rsc) and writes any of
// .h / .c / .xt / .rsc.  Same exporters the editor's File menu uses, so a
// Makefile can regenerate sources without opening the app.

#import <Foundation/Foundation.h>
#import "GModel.h"
#import "GRsc.h"
#import "GProject.h"
#import "GExport.h"

static void usage(void)
    {
    fprintf(stderr,
            "rockscli — compile a GEM resource to source.\n"
            "\n"
            "usage: rockscli <input> [-o <stem>] [--emit <list>] [--cell <WxH>]\n"
            "       rockscli --list <input>\n"
            "       rockscli --help\n"
            "\n"
            "  <input>        a Rocks project (.gemproj) or a GEM resource (.rsc)\n"
            "  -o <stem>      output base path; writes <stem>.h, <stem>.c, ...\n"
            "                 (default: the input path without its extension)\n"
            "  --emit <list>  comma-separated, any of: h, c, xt, rsc   (default: h,c)\n"
            "  --cell <WxH>   coordinate cell used to pack a .rsc  (default: 8x16)\n"
            "  --list         print the trees, objects and exported symbols; emit nothing\n"
            "  -h, --help     this message\n"
            "\n"
            "output kinds:\n"
            "  h    symbolic names — one #define per tree and per object, so code never\n"
            "       hard-codes an index. Also declares the AES structs; #define\n"
            "       ROCKS_AES_TYPES to supply your own from aes.h instead.\n"
            "  c    the trees as static initialised data. C folds address constants, so\n"
            "       every ob_spec is resolved at compile time — nothing to call at\n"
            "       start-up, and no .rsc needed at run time.\n"
            "  xt   the same for the xtc language. Its tables are pure integers (xtc will\n"
            "       not fold a global containing a pointer), so call the generated\n"
            "       <stem>_fixup() once before handing a tree to the AES. Targets\n"
            "       m68k/6502; build with -A 68030, or -A m68k -mpic for a large\n"
            "       resource (plain 68000 PC-relative data only reaches +/-32KB).\n"
            "  rsc  a classic big-endian GEM .rsc\n"
            "\n"
            "Symbols are prefixed with the tree's name: a tree MAIN holding an OK button\n"
            "gives `#define MAIN 0` and `#define MAIN_OK 3`. An object uses its Name from\n"
            "the inspector if set, else its text/label, else its type. A .rsc carries no\n"
            "tree names, so imported trees export as TREE0, TREE1, … until renamed.\n"
            "\n"
            "examples:\n"
            "  rockscli app.gemproj -o build/app                 # app.h + app.c\n"
            "  rockscli app.gemproj -o build/app --emit xt       # app.xt\n"
            "  rockscli legacy.rsc  -o out/legacy --emit h,c,rsc\n"
            "  rockscli old.rsc -o out/old --emit rsc --cell 8x8 # repack at an 8x8 cell\n"
            "  rockscli --list app.rsc\n");
    }

// A .rsc has no tree names, so give the trees usable symbols on the way in.
static GResource* loadResource(NSString* path, NSString** err)
    {
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (!d)
        {
        *err = [NSString stringWithFormat:@"cannot read %@", path];
        return nil;
        }
    NSString* ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"rsc"] || [ext isEqualToString:@"rsrc"])
        {
        GResource* r = GRscRead(d, err);
        NSString* warn = GRscLastImportWarning();
        if (warn)
            fprintf(stderr, "rockscli: warning: %s\n", warn.UTF8String);
        return r;
        }
    GResource* r = GResourceFromJSON(d);
    if (!r)
        *err = @"not a Rocks project (.gemproj)";
    return r;
    }

static int listResource(GResource* r)
    {
    printf("%d tree%s\n", (int)r.trees.count, r.trees.count == 1 ? "" : "s");
    // what came in besides the trees
    int cicon = 0, mono = 0, withSel = 0;
    for (GTree* t in r.trees)
        for (GObject* o in [t allObjects])
            {
            if (o.type == GT_CICONBLK)
                {
                cicon++;
                if (o.icon.selPam)
                    withSel++;
                }
            if (o.type == GT_ICON)
                mono++;
            }
    if (r.freeStrings.count)
        printf("  free strings: %d\n", (int)r.freeStrings.count);
    if (cicon)
        printf("  colour icons (CICONBLK): %d  (%d with a SELECTED form)\n", cicon, withSel);
    if (mono)
        printf("  mono icons (ICONBLK):    %d\n", mono);
    int bb = 0;
    for (GTree* t in r.trees)
        for (GObject* o in [t allObjects])
            if (o.bitblk)
                bb++;
    if (bb)
        printf("  bitmaps (BITBLK):        %d\n", bb);
    if (r.freeImages.count)
        printf("  free images:             %d\n", (int)r.freeImages.count);
    NSDictionary* syms = GExportSymbols(r);
    for (int i = 0; i < (int)r.trees.count; i++)
        {
        GTree* t = r.trees[i];
        printf("\n  [%d] %s — %s, %d objects\n", i, t.name.UTF8String,
               t.isMenu ? "menu" : "dialog", (int)t.allObjects.count);
        }
    printf("\nsymbols (%d):\n", (int)syms.count);
    NSArray* keys = [syms.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* k in keys)
        printf("  %-32s %s\n", k.UTF8String, [syms[k] stringValue].UTF8String);
    return 0;
    }

static BOOL writeText(NSString* text, NSString* path, NSString* what)
    {
    NSError* e = nil;
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e])
        {
        fprintf(stderr, "rockscli: cannot write %s: %s\n",
                path.UTF8String, e.localizedDescription.UTF8String);
        return NO;
        }
    printf("  %-4s %s\n", what.UTF8String, path.UTF8String);
    return YES;
    }

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        NSString *input = nil, *stem = nil, *emit = @"h,c";
        BOOL list = NO;
        int cellW = 8, cellH = 16;

        for (int i = 1; i < argc; i++)
            {
            NSString* a = [NSString stringWithUTF8String:argv[i]];
            if ([a isEqualToString:@"-h"] || [a isEqualToString:@"--help"])
                {
                usage();
                return 0;
                }
            else if ([a isEqualToString:@"--list"])
                list = YES;
            else if ([a isEqualToString:@"-o"] && i + 1 < argc)
                stem = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--emit"] && i + 1 < argc)
                emit = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--cell"] && i + 1 < argc)
                {
                if (sscanf(argv[++i], "%dx%d", &cellW, &cellH) != 2)
                    {
                    fprintf(stderr, "rockscli: --cell wants WxH, e.g. 8x8\n");
                    return 2;
                    }
                }
            else if ([a hasPrefix:@"-"])
                {
                fprintf(stderr, "rockscli: unknown option %s\n", a.UTF8String);
                usage();
                return 2;
                }
            else if (!input)
                input = a;
            else
                {
                fprintf(stderr, "rockscli: unexpected argument %s\n", a.UTF8String);
                return 2;
                }
            }
        if (!input)
            {
            usage();
            return 2;
            }

        NSString* err = nil;
        GResource* res = loadResource(input, &err);
        if (!res)
            {
            fprintf(stderr, "rockscli: %s\n", (err ?: @"could not load input").UTF8String);
            return 1;
            }
        if (list)
            return listResource(res);

        if (!stem)
            stem = [input stringByDeletingPathExtension];
        res.charWidth = cellW;
        res.charHeight = cellH;

        NSSet* want = [NSSet setWithArray:[emit componentsSeparatedByString:@","]];
        NSMutableSet* unknown = [want mutableCopy];
        [unknown minusSet:[NSSet setWithArray:@[ @"h", @"c", @"xt", @"rsc" ]]];
        if (unknown.count)
            {
            fprintf(stderr, "rockscli: unknown --emit kind(s): %s\n",
                    [[unknown.allObjects componentsJoinedByString:@","] UTF8String]);
            return 2;
            }

        // The stem's last path component names the generated symbols and files.
        NSString* base = stem.lastPathComponent;
        NSString* dir = stem.stringByDeletingLastPathComponent;
        if (dir.length)
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];

        printf("rockscli: %s -> %d tree%s\n", input.UTF8String,
               (int)res.trees.count, res.trees.count == 1 ? "" : "s");

        if ([want containsObject:@"h"] &&
            !writeText(GExportHeader(res, base), [stem stringByAppendingPathExtension:@"h"], @"h"))
            return 1;
        if ([want containsObject:@"c"] &&
            !writeText(GExportCSource(res, base), [stem stringByAppendingPathExtension:@"c"], @"c"))
            return 1;
        if ([want containsObject:@"xt"] &&
            !writeText(GExportXtc(res, base), [stem stringByAppendingPathExtension:@"xt"], @"xt"))
            return 1;
        if ([want containsObject:@"rsc"])
            {
            NSString* werr = nil;
            NSData* d = GRscWrite(res, &werr);
            NSString* path = [stem stringByAppendingPathExtension:@"rsc"];
            if (!d)
                {
                fprintf(stderr, "rockscli: .rsc export failed: %s\n",
                        (werr ?: @"unknown error").UTF8String);
                return 1;
                }
            [d writeToFile:path atomically:YES];
            printf("  %-4s %s (%lu bytes)\n", "rsc", path.UTF8String, (unsigned long)d.length);
            }
        return 0;
        }
    }
