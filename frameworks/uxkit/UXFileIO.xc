// UXFileIO.xc — read and write a whole file: what a document-based app needs to open and save.
//
// The stdlib's Files.xc exists only on the host archs, which left an app like Rocks unable to save
// anywhere else.  This is libc's stdio, which every native target UXKit runs on has -- macOS, Linux,
// Windows, iOS and Android in their sandboxes, and GEM through its own libc.  The web has no file
// system: wasm32 goes through the loader's file primitives (_xt_file_*, the stdlib Files.xc's), which
// are real files under node and which the web shim, on a page, answers from a store it keeps by path
// where the module runs; there a write is also the browser's download, and a file the user opens
// (UXOpenPanel) is put in the store by the picker.
//
// SAVING IS ATOMIC.  The bytes go to `path` + ".uxtmp" first and are renamed over the original only
// once all of them are written and the file is closed, so a full disk or a failed write leaves the
// previous document untouched instead of truncating it.  (Windows' rename will not replace an
// existing file, so there the original is removed first -- still after the new bytes are safely on
// disk.)
#import "UXData.xc"
#import "UXLibc.xc"

#if ARCH_wasm32
i32 _xt_file_open(u8* path, u8* mode);
i32 _xt_file_read(i32 handle, u8* buf, u32 n);
i32 _xt_file_write(i32 handle, u8* buf, u32 n);
void _xt_file_close(i32 handle);
i32 _xt_file_size(u8* path);
#else
pointer fopen(u8* path, u8* mode);
i32 fclose(pointer f);
u32 fread(pointer buf, u32 size, u32 n, pointer f);
u32 fwrite(pointer buf, u32 size, u32 n, pointer f);
i32 rename(u8* from, u8* to);
i32 remove(u8* path);
#endif

class UXFileIO
    {
    // The whole file, or null if it cannot be read.
    static UXData* read(u8* path)
        {
#if ARCH_wasm32
        if (path == (u8*)0)
            {
            return (UXData*)0;
            }
        i32 size = _xt_file_size(path);
        if (size < (i32)0)
            {
            return (UXData*)0;
            }
        i32 h = _xt_file_open(path, (u8*)"rb");
        if (h < (i32)0)
            {
            return (UXData*)0;
            }
        UXData* wd = UXData.withCapacity(size > (i32)0 ? size : (i32)1);
        if (size > (i32)0)
            {
            u8* buf = (u8*)malloc((u32)size);
            i32 got = _xt_file_read(h, buf, (u32)size);
            if (got > (i32)0)
                {
                wd.appendBytes(buf, got);
                }
            free((pointer)buf);
            }
        _xt_file_close(h);
        return wd;
#else
        if (path == (u8*)0)
            {
            return (UXData*)0;
            }
        pointer f = fopen(path, (u8*)"rb");
        if (f == (pointer)0)
            {
            return (UXData*)0;
            }
        UXData* d = UXData.withCapacity((i32)4096);
        u8* chunk = (u8*)malloc((u32)4096);
        u32 n = fread((pointer)chunk, (u32)1, (u32)4096, f);
        while (n > (u32)0)
            {
            d.appendBytes(chunk, (i32)n);
            n = fread((pointer)chunk, (u32)1, (u32)4096, f);
            }
        free((pointer)chunk);
        fclose(f);
        return d;
#endif
        }

    // Write `d` to `path`, replacing it only if every byte made it to disk.  True on success.
    static bool write(u8* path, UXData* d)
        {
#if ARCH_wasm32
        if (path == (u8*)0 || d == (UXData*)0)
            {
            return false;
            }
        i32 h = _xt_file_open(path, (u8*)"wb");
        if (h < (i32)0)
            {
            return false;
            }
        i32 want = d.length();
        i32 put = want > (i32)0 ? _xt_file_write(h, d.bytes(), (u32)want) : (i32)0;
        _xt_file_close(h);
        return put == want;
#else
        if (path == (u8*)0 || d == (UXData*)0)
            {
            return false;
            }
        UXData* tn = UXData.fromString(path);
        tn.appendBytes((u8*)".uxtmp", (i32)6);
        tn.appendByte((u8)0);
        u8* tmp = tn.bytes();
        pointer f = fopen(tmp, (u8*)"wb");
        if (f == (pointer)0)
            {
            return false;
            }
        u32 want = (u32)d.length();
        u32 put = want > (u32)0 ? fwrite((pointer)d.bytes(), (u32)1, want, f) : (u32)0;
        bool closed = fclose(f) == (i32)0;
        if (put != want || !closed)
            {
            remove(tmp);
            return false;
            }
        if (rename(tmp, path) != (i32)0)
            {
            // Windows: rename does not replace.  The new bytes are safe in tmp, so clear the way.
            remove(path);
            if (rename(tmp, path) != (i32)0)
                {
                remove(tmp);
                return false;
                }
            }
        return true;
#endif
        }
    }
