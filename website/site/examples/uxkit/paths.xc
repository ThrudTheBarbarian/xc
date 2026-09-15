// paths.xc — UXPath and UXURL: splitting, rebuilding and normalizing, with no
// filesystem anywhere in sight.
//
// Both classes are pure string work, which is why this program needs no driver,
// no window and no disk: every answer below is computed from the text alone.
#import <Stdio.xc>
#import "UXPath.xc"
#import "UXURL.xc"

void show(u8* label, UXPath* p) {
    Stdio.printf("%s '%s'  count=%d abs=%d\n", label, p.toString(), p.count(),
                 p.isAbsolute() ? 1 : 0);
}

void main(void) {
    // ---- splitting -------------------------------------------------------
    UXPath* p = UXPath.parse((u8*)"/usr/local/share/fonts/system.fnt");
    show((u8*)"parsed:      ", p);
    Stdio.printf("last=%s ext=%s stem=%s\n",
                 p.lastComponent(), p.pathExtension(),
                 p.lastComponentWithoutExtension());

    // Empty components are dropped, so doubled and trailing slashes vanish and
    // toString() gives back a tidied path.
    show((u8*)"messy:       ", UXPath.parse((u8*)"//usr//local///bin/"));

    // ---- rebuilding ------------------------------------------------------
    // Every mutator returns a NEW path; the receiver is untouched.
    UXPath* dir  = p.deletingLastComponent();
    UXPath* next = dir.appendingComponent((u8*)"mono.fnt");
    show((u8*)"dir:         ", dir);
    show((u8*)"sibling:     ", next);
    show((u8*)"original:    ", p);

    // ---- extensions ------------------------------------------------------
    // The LAST dot splits, so a double extension keeps its first half in the stem.
    UXPath* tgz = UXPath.parse((u8*)"backup.tar.gz");
    Stdio.printf("tar.gz: ext=%s stem=%s\n",
                 tgz.pathExtension(), tgz.lastComponentWithoutExtension());

    // A leading dot is a hidden FILE, not an extension.
    UXPath* rc = UXPath.parse((u8*)"/home/user/.profile");
    Stdio.printf("dotfile: ext='%s' stem=%s\n",
                 rc.pathExtension(), rc.lastComponentWithoutExtension());

    // ---- normalizing -----------------------------------------------------
    // "." and ".." are resolved by TEXT: no stat, no symlinks, no disk.
    show((u8*)"abs before:  ", UXPath.parse((u8*)"/a/b/./c/../../d"));
    show((u8*)"abs after:   ", UXPath.parse((u8*)"/a/b/./c/../../d").normalized());

    // At the root, ".." has nowhere to go and is discarded — as on a real
    // filesystem, where /.. is /.
    show((u8*)"above root:  ", UXPath.parse((u8*)"/../../etc").normalized());

    // But a RELATIVE path keeps its leading "..", because "../sibling" means
    // something and dropping it would change where the path points.
    show((u8*)"relative:    ", UXPath.parse((u8*)"../../etc/passwd").normalized());
    show((u8*)"rel mixed:   ", UXPath.parse((u8*)"a/../../b").normalized());

    // ---- URLs ------------------------------------------------------------
    UXURL* u = UXURL.parse((u8*)"https://example.org:8443/docs/uxkit?tab=api#paths");
    Stdio.printf("url scheme=%s host=%s port=%d\n", u.scheme, u.host, u.port);
    Stdio.printf("    path=%s query=%s fragment=%s\n", u.path, u.query, u.fragment);
    Stdio.printf("    last=%s rebuilt=%s\n", u.lastPathComponent(), u.toString());

    // No port given means -1 — "use the scheme's default" — which is not the
    // same as port 0, and is why the rebuilt string has no colon.
    UXURL* plain = UXURL.parse((u8*)"http://example.com/index.html");
    Stdio.printf("no port: port=%d rebuilt=%s\n", plain.port, plain.toString());

    // A string with no "://" has no scheme and no host: it is all path. That is
    // how a bare filename survives parse() unchanged.
    UXURL* bare = UXURL.parse((u8*)"notes/today.md");
    Stdio.printf("bare: scheme='%s' host='%s' path=%s\n",
                 bare.scheme, bare.host, bare.path);

    // file: URLs are the bridge to UXPath — the pasteboard and the file panel
    // both speak them.
    UXURL* f = UXURL.fileURL((u8*)"/usr/local/share/fonts/system.fnt");
    Stdio.printf("file url: %s isFile=%d name=%s\n",
                 f.toString(), f.isFileURL() ? 1 : 0, f.lastPathComponent());
    show((u8*)"back to path:", UXPath.parse(f.path));
}
