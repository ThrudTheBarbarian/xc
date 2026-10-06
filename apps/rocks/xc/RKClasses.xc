// RKClasses.xc — what the designer knows about classes: their parents, outlets and actions.
//
// Three sources, in the order they are trusted:
//   - REFLECTED: the app's own classes, read from what the app is actually made of, never from a
//     generated side file that can fall behind it:
//       - its SOURCE: every .xc file under the document's folder, parsed for classes, their
//         parents, `outlet` fields and `:action` methods;
//       - a LIBRARY (.dylib, .so, .dll) dropped on the window or added from the File menu: the
//         compiler builds the module's interface into it (Mach-O __XTC,__iface; ELF .xtc.iface;
//         PE xtciface), JSON in which a designable class lists its outlets and actions.
//   - DECLARED: a class Rocks cannot see, declared by hand in the Identity inspector and kept in
//     the document (a DECL section of the nib chunk), as Interface Builder lets you add outlets and
//     actions to a class before it is written.
//   - UXKIT: the toolkit's own view classes, so an outlet typed UXButton* can be told a UXButton
//     from a UXLabel.  They have no outlets or actions of their own to connect.
//
// A reflected class wins over a declared one of the same name: once the code exists, the code is
// the truth, and a declaration left behind is shown as such.
#import "Array.xc"
#import "Data.xc"
#import "UXJSON.xc"
#import "UXFileIO.xc"
#import "UXRscModel.xc"

#define RKC_UXKIT 0
#define RKC_REFLECTED 1
#define RKC_DECLARED 2

// An outlet (name, the type it holds) or an action (name, the sender's type).
class RKMember : Object
    {
    u8* name;
    u8* type;
    static RKMember* make(u8* name, u8* type)
        {
        RKMember* m = new RKMember();
        m.name = name;
        m.type = type;
        return m;
        }
    }

class RKClass : Object
    {
    u8* name;
    u8* parent; // "" for a root
    Array<RKMember>* outlets;
    Array<RKMember>* actions;
    i32 origin; // RKC_*
    u8* source; // where a reflected class was read from

    void init(void)
        {
        name = (u8*)"";
        parent = (u8*)"";
        outlets = new Array();
        actions = new Array();
        origin = (i32)RKC_UXKIT;
        source = (u8*)"";
        }
    static RKClass* make(u8* name, u8* parent, i32 origin)
        {
        RKClass* c = new RKClass();
        c.name = name;
        c.parent = parent;
        c.origin = origin;
        return c;
        }
    }

// Classes as the app's source declares them: `class Name : Parent`, its `outlet` fields and its
// `:action` methods.  A scanner, not a compiler: it reads declarations at the top of a class body
// and skips method bodies, comments, strings and preprocessor lines, which is all a designer needs.
class RKSourceScan : Object
    {
    u8* src;
    i32 len;
    i32 pos;
    Array<Data>* toks; // the current statement's tokens

    static Array<RKClass>* classesIn(u8* text, i32 n, u8* path)
        {
        RKSourceScan* sc = new RKSourceScan();
        sc.src = text;
        sc.len = n;
        sc.pos = (i32)0;
        return sc.scan(path);
        }

    Array<RKClass>* scan(u8* path)
        {
        Array<RKClass>* out = new Array();
        i32 depth = (i32)0;
        RKClass* cur = (RKClass*)0; // the class whose body is open
        i32 bodyDepth = (i32)-1;
        RKClass* pending = (RKClass*)0; // seen `class X : Y`, waiting for its brace
        toks = new Array();
        while (true)
            {
            u8* t = self.next();
            if (t == (u8*)0)
                {
                break;
                }
            if (RKClassBook.seq(t, (u8*)"{"))
                {
                if (pending != (RKClass*)0 && depth == (i32)0)
                    {
                    cur = pending;
                    pending = (RKClass*)0;
                    bodyDepth = depth + (i32)1;
                    out.add(cur);
                    }
                else if (cur != (RKClass*)0 && depth == bodyDepth)
                    {
                    self.member(cur, true);
                    }
                toks = new Array();
                depth = depth + (i32)1;
                continue;
                }
            if (RKClassBook.seq(t, (u8*)"}"))
                {
                depth = depth - (i32)1;
                if (cur != (RKClass*)0 && depth < bodyDepth)
                    {
                    cur = (RKClass*)0;
                    bodyDepth = (i32)-1;
                    }
                toks = new Array();
                continue;
                }
            if (RKClassBook.seq(t, (u8*)";"))
                {
                if (cur != (RKClass*)0 && depth == bodyDepth)
                    {
                    self.member(cur, false);
                    }
                toks = new Array();
                continue;
                }
            if (depth == (i32)0 && RKClassBook.seq(t, (u8*)"class"))
                {
                u8* name = self.next();
                if (name == (u8*)0)
                    {
                    break;
                    }
                pending = RKClass.make(name, (u8*)"", (i32)RKC_REFLECTED);
                pending.source = path;
                u8* colon = self.peekTok();
                if (colon != (u8*)0 && RKClassBook.seq(colon, (u8*)":"))
                    {
                    self.next();
                    u8* parent = self.next();
                    if (parent != (u8*)0)
                        {
                        pending.parent = parent;
                        }
                    }
                toks = new Array();
                continue;
                }
            if (cur != (RKClass*)0 && depth == bodyDepth)
                {
                toks.add(UXStr.toData(t));
                }
            }
        return out;
        }
    // A statement at the top of a class body, ended by ';' (a field) or '{' (a method's body).
    void member(RKClass* c, bool method)
        {
        i32 n = (i32)toks.count();
        if (n == (i32)0)
            {
            return;
            }
        if (method)
            {
            // void name(Type* sender) : action
            if (n < (i32)2 || !RKSourceScan.is(self.tok(n - (i32)1), (u8*)"action") || !RKSourceScan.is(self.tok(n - (i32)2), (u8*)":"))
                {
                return;
                }
            i32 open = (i32)-1;
            i32 close = (i32)-1;
            for (i32 i = (i32)0; i < n; i = i + (i32)1)
                {
                if (open < (i32)0 && RKSourceScan.is(self.tok(i), (u8*)"("))
                    {
                    open = i;
                    }
                if (RKSourceScan.is(self.tok(i), (u8*)")"))
                    {
                    close = i;
                    }
                }
            if (open < (i32)1 || close < open)
                {
                return;
                }
            // the sender's type: the parameter's tokens but its name
            Data* ty = Data.withCapacity((u32)((i32)32));
            for (i32 i = open + (i32)1; i < close - (i32)1; i = i + (i32)1)
                {
                ty.appendBytes(self.tok(i), RKClassBook.slen(self.tok(i)));
                }
            ty.appendByte((u8)0);
            c.actions.add(RKMember.make(self.tok(open - (i32)1), UXStr.cstr(ty)));
            return;
            }
        bool isOutlet = false;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if (RKSourceScan.is(self.tok(i), (u8*)"outlet"))
                {
                isOutlet = true;
                }
            if (RKSourceScan.is(self.tok(i), (u8*)"("))
                {
                return; // a method's prototype, not a field
                }
            }
        if (!isOutlet || n < (i32)3)
            {
            return;
            }
        // [qualifiers] Type * name -- the qualifiers, and their optional colons, are not the type
        Data* ty = Data.withCapacity((u32)((i32)32));
        for (i32 i = (i32)0; i < n - (i32)1; i = i + (i32)1)
            {
            u8* t = self.tok(i);
            if (RKSourceScan.is(t, (u8*)"outlet") || RKSourceScan.is(t, (u8*)"weak") || RKSourceScan.is(t, (u8*)"strong") ||
                RKSourceScan.is(t, (u8*)"banked") || RKSourceScan.is(t, (u8*)":"))
                {
                continue;
                }
            ty.appendBytes(t, RKClassBook.slen(t));
            }
        ty.appendByte((u8)0);
        c.outlets.add(RKMember.make(self.tok(n - (i32)1), UXStr.cstr(ty)));
        }
    u8* tok(i32 i)
        {
        return UXStr.cstr((Data* ?)toks.get((u32)i));
        }
    static bool is(u8* a, u8* b)
        {
        return RKClassBook.seq(a, b);
        }

    // ---- tokens --------------------------------------------------------------------------------
    u8* peekTok(void)
        {
        i32 save = pos;
        u8* t = self.next();
        pos = save;
        return t;
        }
    // The next token, or 0 at the end: an identifier or a number, or one punctuation character.
    u8* next(void)
        {
        while (pos < len)
            {
            u8 c = src[pos];
            if (c == (u8)32 || c == (u8)9 || c == (u8)10 || c == (u8)13)
                {
                pos = pos + (i32)1;
                continue;
                }
            if (c == (u8)'/' && pos + (i32)1 < len && src[pos + (i32)1] == (u8)'/')
                {
                self.skipLine();
                continue;
                }
            if (c == (u8)'/' && pos + (i32)1 < len && src[pos + (i32)1] == (u8)'*')
                {
                pos = pos + (i32)2;
                while (pos + (i32)1 < len && !(src[pos] == (u8)'*' && src[pos + (i32)1] == (u8)'/'))
                    {
                    pos = pos + (i32)1;
                    }
                pos = pos + (i32)2;
                continue;
                }
            if (c == (u8)'#' && self.atLineStart())
                {
                self.skipLine();
                continue;
                }
            if (c == (u8)34 || c == (u8)39)
                {
                // a string or a character: skipped, escapes and all
                pos = pos + (i32)1;
                while (pos < len && src[pos] != c)
                    {
                    pos = pos + (src[pos] == (u8)92 ? (i32)2 : (i32)1);
                    }
                pos = pos + (i32)1;
                continue;
                }
            i32 start = pos;
            if (RKSourceScan.word(c))
                {
                while (pos < len && RKSourceScan.word(src[pos]))
                    {
                    pos = pos + (i32)1;
                    }
                }
            else
                {
                pos = pos + (i32)1;
                }
            u8* t = new u8[(u32)(pos - start + (i32)1)];
            for (i32 i = (i32)0; i < pos - start; i = i + (i32)1)
                {
                t[i] = src[start + i];
                }
            t[pos - start] = (u8)0;
            return t;
            }
        return (u8*)0;
        }
    static bool word(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9') ||
               c == (u8)'_' || c == (u8)'$';
        }
    bool atLineStart(void)
        {
        i32 i = pos - (i32)1;
        while (i >= (i32)0 && (src[i] == (u8)32 || src[i] == (u8)9))
            {
            i = i - (i32)1;
            }
        return i < (i32)0 || src[i] == (u8)10;
        }
    void skipLine(void)
        {
        while (pos < len && src[pos] != (u8)10)
            {
            pos = pos + (i32)1;
            }
        }
    }

// Where a library keeps the interface the compiler built into it: the __iface section of the
// __XTC segment (Mach-O), the .xtc.iface section (ELF), the xtciface section (PE).  Little-endian
// files, as every target the compiler writes libraries for.
class RKBinary : Object
    {
    static u32 u16at(u8* b, i32 at)
        {
        return (u32)b[at] | ((u32)b[at + (i32)1] << (u32)8);
        }
    static u32 u32at(u8* b, i32 at)
        {
        return RKBinary.u16at(b, at) | (RKBinary.u16at(b, at + (i32)2) << (u32)16);
        }
    static bool name(u8* b, i32 at, i32 cap, u8* want)
        {
        i32 i = (i32)0;
        while (want[i] != (u8)0)
            {
            if (i >= cap || b[at + i] != want[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return i >= cap || b[at + i] == (u8)0;
        }
    // The section's offset in the file (its length in len[0]), or -1.  Trailing NULs are not part
    // of it.
    static i32 ifaceSection(u8* b, i32 n, i32* len)
        {
        i32 at = (i32)-1;
        if (n >= (i32)32 && RKBinary.u32at(b, (i32)0) == (u32)$FEEDFACF)
            {
            at = RKBinary.machO(b, n, len);
            }
        else if (n >= (i32)52 && b[0] == (u8)$7F && b[1] == (u8)'E' && b[2] == (u8)'L' && b[3] == (u8)'F')
            {
            at = RKBinary.elf(b, n, len);
            }
        else if (n >= (i32)64 && b[0] == (u8)'M' && b[1] == (u8)'Z')
            {
            at = RKBinary.pe(b, n, len);
            }
        if (at < (i32)0 || at + len[0] > n)
            {
            return (i32)-1;
            }
        while (len[0] > (i32)0 && b[at + len[0] - (i32)1] == (u8)0)
            {
            len[0] = len[0] - (i32)1;
            }
        return at;
        }
    static i32 machO(u8* b, i32 n, i32* len)
        {
        i32 ncmds = (i32)RKBinary.u32at(b, (i32)16);
        i32 p = (i32)32;
        for (i32 c = (i32)0; c < ncmds && p + (i32)8 <= n; c = c + (i32)1)
            {
            u32 cmd = RKBinary.u32at(b, p);
            i32 size = (i32)RKBinary.u32at(b, p + (i32)4);
            if (cmd == (u32)$19 && RKBinary.name(b, p + (i32)8, (i32)16, (u8*)"__XTC"))
                {
                i32 ns = (i32)RKBinary.u32at(b, p + (i32)64);
                for (i32 s = (i32)0; s < ns; s = s + (i32)1)
                    {
                    i32 sp = p + (i32)72 + s * (i32)80;
                    if (sp + (i32)80 <= n && RKBinary.name(b, sp, (i32)16, (u8*)"__iface"))
                        {
                        len[0] = (i32)RKBinary.u32at(b, sp + (i32)40);
                        return (i32)RKBinary.u32at(b, sp + (i32)48);
                        }
                    }
                }
            if (size <= (i32)0)
                {
                return (i32)-1;
                }
            p = p + size;
            }
        return (i32)-1;
        }
    static i32 elf(u8* b, i32 n, i32* len)
        {
        bool is64 = b[4] == (u8)2;
        i32 shoff = (i32)RKBinary.u32at(b, is64 ? (i32)$28 : (i32)$20);
        i32 shentsize = (i32)RKBinary.u16at(b, is64 ? (i32)$3A : (i32)$2E);
        i32 shnum = (i32)RKBinary.u16at(b, is64 ? (i32)$3C : (i32)$30);
        i32 shstrndx = (i32)RKBinary.u16at(b, is64 ? (i32)$3E : (i32)$32);
        if (shoff <= (i32)0 || shoff + shnum * shentsize > n || shstrndx >= shnum)
            {
            return (i32)-1;
            }
        i32 strs = shoff + shstrndx * shentsize;
        i32 strOff = (i32)RKBinary.u32at(b, strs + (is64 ? (i32)$18 : (i32)$10));
        for (i32 s = (i32)0; s < shnum; s = s + (i32)1)
            {
            i32 sh = shoff + s * shentsize;
            i32 nm = strOff + (i32)RKBinary.u32at(b, sh);
            if (nm < n && RKBinary.name(b, nm, n - nm, (u8*)".xtc.iface"))
                {
                len[0] = (i32)RKBinary.u32at(b, sh + (is64 ? (i32)$20 : (i32)$14));
                return (i32)RKBinary.u32at(b, sh + (is64 ? (i32)$18 : (i32)$10));
                }
            }
        return (i32)-1;
        }
    static i32 pe(u8* b, i32 n, i32* len)
        {
        i32 pe = (i32)RKBinary.u32at(b, (i32)$3C);
        if (pe + (i32)24 > n || b[pe] != (u8)'P' || b[pe + (i32)1] != (u8)'E')
            {
            return (i32)-1;
            }
        i32 nsec = (i32)RKBinary.u16at(b, pe + (i32)6);
        i32 optSize = (i32)RKBinary.u16at(b, pe + (i32)20);
        i32 st = pe + (i32)24 + optSize;
        for (i32 s = (i32)0; s < nsec; s = s + (i32)1)
            {
            i32 sh = st + s * (i32)40;
            if (sh + (i32)40 <= n && RKBinary.name(b, sh, (i32)8, (u8*)"xtciface"))
                {
                i32 vsize = (i32)RKBinary.u32at(b, sh + (i32)8);
                i32 raw = (i32)RKBinary.u32at(b, sh + (i32)16);
                len[0] = vsize > (i32)0 && vsize <= raw ? vsize : raw;
                return (i32)RKBinary.u32at(b, sh + (i32)20);
                }
            }
        return (i32)-1;
        }
    }

class RKClassBook : Object
    {
    Array<RKClass>* classes;

    void init(void)
        {
        classes = new Array();
        self.addUXKit();
        }

    // ---- lookup ------------------------------------------------------------------------------
    RKClass* find(u8* name)
        {
        if (name == (u8*)0 || name[0] == (u8)0)
            {
            return (RKClass*)0;
            }
        RKClass* declared = (RKClass*)0;
        for (u32 i = (u32)0; i < classes.count(); i = i + (u32)1)
            {
            RKClass* c = (RKClass* ?)classes.get(i);
            if (RKClassBook.seq(c.name, name))
                {
                if (c.origin != (i32)RKC_DECLARED)
                    {
                    return c;
                    }
                declared = c;
                }
            }
        return declared;
        }
    // Whether `name` is `ancestor` or a subclass of it.  "Object" is everything's ancestor.
    bool isKindOf(u8* name, u8* ancestor)
        {
        if (RKClassBook.seq(ancestor, (u8*)"Object"))
            {
            return true;
            }
        u8* n = name;
        for (i32 guard = (i32)0; guard < (i32)64 && n != (u8*)0 && n[0] != (u8)0; guard = guard + (i32)1)
            {
            if (RKClassBook.seq(n, ancestor))
                {
                return true;
                }
            RKClass* c = self.find(n);
            if (c == (RKClass*)0)
                {
                return false;
                }
            n = c.parent;
            }
        return false;
        }
    // Every outlet (or action) of a class and its ancestors, nearest first.
    Array<RKMember>* outletsOf(u8* name)
        {
        return self.collect(name, true);
        }
    Array<RKMember>* actionsOf(u8* name)
        {
        return self.collect(name, false);
        }
    Array<RKMember>* collect(u8* name, bool outlets)
        {
        Array<RKMember>* out = new Array();
        u8* n = name;
        for (i32 guard = (i32)0; guard < (i32)64 && n != (u8*)0 && n[0] != (u8)0; guard = guard + (i32)1)
            {
            RKClass* c = self.find(n);
            if (c == (RKClass*)0)
                {
                break;
                }
            Array<RKMember>* ms = outlets ? c.outlets : c.actions;
            for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
                {
                out.add(ms.get(i));
                }
            n = c.parent;
            }
        return out;
        }
    // An outlet's type without its pointer star ("UXButton*" -> "UXButton").
    static u8* bareType(u8* t)
        {
        i32 n = RKClassBook.slen(t);
        while (n > (i32)0 && (t[n - (i32)1] == (u8)'*' || t[n - (i32)1] == (u8)' '))
            {
            n = n - (i32)1;
            }
        u8* b = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            b[i] = t[i];
            }
        b[n] = (u8)0;
        return b;
        }
    // Whether an object of class `cls` may be connected to an outlet of type `type`.
    bool fits(u8* cls, u8* type)
        {
        return self.isKindOf(cls, RKClassBook.bareType(type));
        }

    // ---- reflected: a library's built-in interface ------------------------------------------
    // Read the interface out of a library; returns how many designable classes it had, -1 if the
    // file is not a library with one.
    i32 loadLibrary(u8* path)
        {
        Data* d = UXFileIO.read(path);
        if (d == (Data*)0)
            {
            return (i32)-1;
            }
        i32 len = (i32)0;
        i32 at = RKBinary.ifaceSection(d.bytes(), d.length(), &len);
        if (at < (i32)0)
            {
            return (i32)-1;
            }
        u8* json = new u8[(u32)(len + (i32)1)];
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            json[i] = d.bytes()[at + i];
            }
        json[len] = (u8)0;
        return self.loadJson(json, path);
        }
    // The interface JSON the compiler writes: every class joins the book (parents are needed for
    // the chain), replacing an earlier reading of the same name.
    i32 loadJson(u8* json, u8* source)
        {
        UXJSONValue* root = UXJSON.parse(json);
        if (root == (UXJSONValue*)0 || !root.has((u8*)"classes"))
            {
            return (i32)-1;
            }
        UXJSONValue* cs = root.get((u8*)"classes");
        i32 designable = (i32)0;
        for (i32 i = (i32)0; i < cs.count(); i = i + (i32)1)
            {
            UXJSONValue* cv = cs.at(i);
            if (!cv.has((u8*)"name"))
                {
                continue;
                }
            RKClass* c = RKClass.make(cv.get((u8*)"name").asString(),
                                      cv.has((u8*)"parent") ? cv.get((u8*)"parent").asString() : (u8*)"",
                                      (i32)RKC_REFLECTED);
            c.source = source;
            if (cv.has((u8*)"outlets"))
                {
                UXJSONValue* os = cv.get((u8*)"outlets");
                for (i32 k = (i32)0; k < os.count(); k = k + (i32)1)
                    {
                    c.outlets.add(RKMember.make(os.at(k).get((u8*)"name").asString(), os.at(k).get((u8*)"type").asString()));
                    }
                }
            if (cv.has((u8*)"actions"))
                {
                UXJSONValue* as = cv.get((u8*)"actions");
                for (i32 k = (i32)0; k < as.count(); k = k + (i32)1)
                    {
                    c.actions.add(RKMember.make(as.at(k).get((u8*)"name").asString(), as.at(k).get((u8*)"sender").asString()));
                    }
                }
            if (cv.has((u8*)"designable") && cv.get((u8*)"designable").asBool())
                {
                designable = designable + (i32)1;
                }
            self.adopt(c);
            }
        return designable;
        }
    // A reflected class in place of any earlier reading of the same name.
    void adopt(RKClass* c)
        {
        self.removeNamed(c.name, (i32)RKC_REFLECTED);
        classes.add(c);
        }

    // ---- reflected: the app's source ---------------------------------------------------------
    // Parse one .xc file; returns how many classes it defines.
    i32 loadSource(u8* path)
        {
        Data* d = UXFileIO.read(path);
        if (d == (Data*)0)
            {
            return (i32)-1;
            }
        Array<RKClass>* found = RKSourceScan.classesIn(d.bytes(), d.length(), path);
        for (u32 i = (u32)0; i < found.count(); i = i + (u32)1)
            {
            self.adopt((RKClass* ?)found.get(i));
            }
        return (i32)found.count();
        }
    // Parse every .xc file under `dir`, `depth` folders deep (build output and hidden folders
    // skipped); returns how many files were read.
    i32 loadTree(u8* dir, i32 depth)
        {
        if (gDriver == (UXViewDriver*)0 || dir == (u8*)0 || depth < (i32)0)
            {
            return (i32)0;
            }
        u8* buf = new u8[(u32)32768];
        // listDir answers how many entries it listed; the listing itself ends at its NUL
        if (gDriver.listDir(dir, buf, (i32)32768) <= (i32)0)
            {
            return (i32)0;
            }
        i32 n = (i32)32768;
        i32 files = (i32)0;
        i32 at = (i32)0;
        while (at < n && buf[at] != (u8)0)
            {
            i32 end = at;
            while (end < n && buf[end] != (u8)10 && buf[end] != (u8)0)
                {
                end = end + (i32)1;
                }
            // a line is "<t>\t<size>\t<name>": t is 'd' for a folder; the name follows the last tab
            i32 nameAt = at;
            for (i32 k = at; k < end; k = k + (i32)1)
                {
                if (buf[k] == (u8)9)
                    {
                    nameAt = k + (i32)1;
                    }
                }
            bool isDir = buf[at] == (u8)'d';
            if (end > nameAt && buf[nameAt] != (u8)'.')
                {
                Data* p = UXStr.toData(dir);
                p.appendByte((u8)'/');
                p.appendBytes(&buf[nameAt], end - nameAt);
                p.appendByte((u8)0);
                if (isDir)
                    {
                    if (!RKClassBook.isBuildDir(buf, nameAt, end))
                        {
                        files = files + self.loadTree(p.bytes(), depth - (i32)1);
                        }
                    }
                else if (RKClassBook.endsWith(buf, nameAt, end, (u8*)".xc") && self.loadSource(p.bytes()) >= (i32)0)
                    {
                    files = files + (i32)1;
                    }
                }
            at = end + (i32)1;
            }
        return files;
        }
    static bool isBuildDir(u8* b, i32 from, i32 end)
        {
        return RKClassBook.named(b, from, end, (u8*)"build") || RKClassBook.named(b, from, end, (u8*)"node_modules") ||
               RKClassBook.named(b, from, end, (u8*)"dist");
        }
    static bool named(u8* b, i32 from, i32 end, u8* w)
        {
        return end - from == RKClassBook.slen(w) && RKClassBook.endsWith(b, from, end, w);
        }

    // ---- declared: kept in the document ------------------------------------------------------
    RKClass* declare(u8* name, u8* parent)
        {
        RKClass* c = self.declared(name);
        if (c != (RKClass*)0)
            {
            return c;
            }
        c = RKClass.make(name, parent, (i32)RKC_DECLARED);
        classes.add(c);
        return c;
        }
    RKClass* declared(u8* name)
        {
        for (u32 i = (u32)0; i < classes.count(); i = i + (u32)1)
            {
            RKClass* c = (RKClass* ?)classes.get(i);
            if (c.origin == (i32)RKC_DECLARED && RKClassBook.seq(c.name, name))
                {
                return c;
                }
            }
        return (RKClass*)0;
        }
    void removeNamed(u8* name, i32 origin)
        {
        u32 i = (u32)0;
        while (i < classes.count())
            {
            RKClass* c = (RKClass* ?)classes.get(i);
            if (c.origin == origin && RKClassBook.seq(c.name, name))
                {
                classes.removeAt(i);
                }
            else
                {
                i = i + (u32)1;
                }
            }
        }

    // The DECL section: { count u16, then per class: name, parent, nOutlets u16, (name, type)...,
    // nActions u16, (name, sender)... }, each string a u16 length and its bytes.
    static u32 tag(void)
        {
        return (u32)$4445434C; // 'DECL'
        }
    // Replace the document's DECL section with this book's declared classes (none: no section).
    void saveTo(UXRscDoc* doc)
        {
        u32 i = (u32)0;
        while (i < doc.extSections.count())
            {
            if (((UXRscExtSection* ?)doc.extSections.get(i)).tag == RKClassBook.tag())
                {
                doc.extSections.removeAt(i);
                }
            else
                {
                i = i + (u32)1;
                }
            }
        Data* b = Data.withCapacity((u32)((i32)128));
        i32 n = (i32)0;
        RKClassBook.be16(b, (i32)0);
        for (u32 k = (u32)0; k < classes.count(); k = k + (u32)1)
            {
            RKClass* c = (RKClass* ?)classes.get(k);
            if (c.origin != (i32)RKC_DECLARED)
                {
                continue;
                }
            n = n + (i32)1;
            RKClassBook.str(b, c.name);
            RKClassBook.str(b, c.parent);
            RKClassBook.members(b, c.outlets);
            RKClassBook.members(b, c.actions);
            }
        if (n == (i32)0)
            {
            return;
            }
        b.bytes()[0] = (u8)((n >> (i32)8) & (i32)$FF);
        b.bytes()[1] = (u8)(n & (i32)$FF);
        UXRscExtSection* x = new UXRscExtSection();
        x.tag = RKClassBook.tag();
        x.body = b;
        doc.extSections.add(x);
        }
    // Take the document's declared classes into the book (replacing any read before).
    void loadFrom(UXRscDoc* doc)
        {
        u32 i = (u32)0;
        while (i < classes.count())
            {
            if (((RKClass* ?)classes.get(i)).origin == (i32)RKC_DECLARED)
                {
                classes.removeAt(i);
                }
            else
                {
                i = i + (u32)1;
                }
            }
        for (u32 k = (u32)0; k < doc.extSections.count(); k = k + (u32)1)
            {
            UXRscExtSection* x = (UXRscExtSection* ?)doc.extSections.get(k);
            if (x.tag != RKClassBook.tag())
                {
                continue;
                }
            u8* p = x.body.bytes();
            i32 len = x.body.length();
            i32 at = (i32)2;
            i32 n = len >= (i32)2 ? (((i32)p[0] << (i32)8) | (i32)p[1]) : (i32)0;
            for (i32 c = (i32)0; c < n && at < len; c = c + (i32)1)
                {
                u8* name = RKClassBook.rdStr(p, len, &at);
                u8* parent = RKClassBook.rdStr(p, len, &at);
                RKClass* cl = RKClass.make(name, parent, (i32)RKC_DECLARED);
                RKClassBook.rdMembers(p, len, &at, cl.outlets);
                RKClassBook.rdMembers(p, len, &at, cl.actions);
                classes.add(cl);
                }
            }
        }
    static void be16(Data* d, i32 v)
        {
        d.appendByte((u8)((v >> (i32)8) & (i32)$FF));
        d.appendByte((u8)(v & (i32)$FF));
        }
    static void str(Data* d, u8* s)
        {
        i32 n = s != (u8*)0 ? RKClassBook.slen(s) : (i32)0;
        RKClassBook.be16(d, n);
        if (n > (i32)0)
            {
            d.appendBytes(s, n);
            }
        }
    static void members(Data* d, Array<RKMember>* ms)
        {
        RKClassBook.be16(d, (i32)ms.count());
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            {
            RKMember* m = (RKMember* ?)ms.get(i);
            RKClassBook.str(d, m.name);
            RKClassBook.str(d, m.type);
            }
        }
    static u8* rdStr(u8* p, i32 len, i32* at)
        {
        if (at[0] + (i32)2 > len)
            {
            at[0] = len;
            return (u8*)"";
            }
        i32 n = ((i32)p[at[0]] << (i32)8) | (i32)p[at[0] + (i32)1];
        at[0] = at[0] + (i32)2;
        if (at[0] + n > len)
            {
            at[0] = len;
            return (u8*)"";
            }
        u8* s = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            s[i] = p[at[0] + i];
            }
        s[n] = (u8)0;
        at[0] = at[0] + n;
        return s;
        }
    static void rdMembers(u8* p, i32 len, i32* at, Array<RKMember>* into)
        {
        if (at[0] + (i32)2 > len)
            {
            return;
            }
        i32 n = ((i32)p[at[0]] << (i32)8) | (i32)p[at[0] + (i32)1];
        at[0] = at[0] + (i32)2;
        for (i32 i = (i32)0; i < n && at[0] < len; i = i + (i32)1)
            {
            u8* name = RKClassBook.rdStr(p, len, at);
            u8* type = RKClassBook.rdStr(p, len, at);
            into.add(RKMember.make(name, type));
            }
        }

    // ---- UXKit's own view classes --------------------------------------------------------------
    void addUXKit(void)
        {
        self.ux((u8*)"Object", (u8*)"");
        self.ux((u8*)"UXResponder", (u8*)"Object");
        self.ux((u8*)"UXView", (u8*)"UXResponder");
        self.ux((u8*)"UXControl", (u8*)"UXView");
        self.ux((u8*)"UXButton", (u8*)"UXControl");
        self.ux((u8*)"UXCheckbox", (u8*)"UXControl");
        self.ux((u8*)"UXRadioButton", (u8*)"UXControl");
        self.ux((u8*)"UXLabel", (u8*)"UXControl");
        self.ux((u8*)"UXTextField", (u8*)"UXControl");
        self.ux((u8*)"UXPopUpButton", (u8*)"UXControl");
        self.ux((u8*)"UXComboBox", (u8*)"UXControl");
        self.ux((u8*)"UXSlider", (u8*)"UXControl");
        self.ux((u8*)"UXStepper", (u8*)"UXControl");
        self.ux((u8*)"UXProgressBar", (u8*)"UXControl");
        self.ux((u8*)"UXSegmentedControl", (u8*)"UXControl");
        self.ux((u8*)"UXDatePicker", (u8*)"UXControl");
        self.ux((u8*)"UXToolbar", (u8*)"UXControl");
        self.ux((u8*)"UXGroupBox", (u8*)"UXView");
        self.ux((u8*)"UXScrollView", (u8*)"UXView");
        self.ux((u8*)"UXSplitView", (u8*)"UXView");
        self.ux((u8*)"UXTabView", (u8*)"UXView");
        self.ux((u8*)"UXTableView", (u8*)"UXView");
        self.ux((u8*)"UXOutlineView", (u8*)"UXTableView");
        self.ux((u8*)"UXGLView", (u8*)"UXView");
        }
    void ux(u8* name, u8* parent)
        {
        classes.add(RKClass.make(name, parent, (i32)RKC_UXKIT));
        }

    // ---- strings -------------------------------------------------------------------------------
    static bool seq(u8* a, u8* b)
        {
        if (a == (u8*)0 || b == (u8*)0)
            {
            return a == b;
            }
        i32 i = (i32)0;
        while (a[i] != (u8)0 && a[i] == b[i])
            {
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }
    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    static bool endsWith(u8* b, i32 from, i32 end, u8* suffix)
        {
        i32 n = RKClassBook.slen(suffix);
        if (end - from < n)
            {
            return false;
            }
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if (b[end - n + i] != suffix[i])
                {
                return false;
                }
            }
        return true;
        }
    }
