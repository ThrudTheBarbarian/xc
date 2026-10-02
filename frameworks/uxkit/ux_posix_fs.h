/* ux_posix_fs.h — the file operations UXKit's drawn file panel needs, for every POSIX backend.
 *
 * UXFilePanel (open and save) lists a folder through the driver's listDir and runs Delete / Rename /
 * Copy / Move through fileDelete / fileRename / fileCopy.  GEM and Win32 have their own; the POSIX
 * backends -- GTK on Linux, AppKit, iOS, Android -- stubbed all four, so wherever the drawn panel was
 * the only file panel (GTK, and the save panel everywhere but AppKit) it showed an empty folder.
 * This is ONE implementation, #included into each of those shims (libUXGtk.c, libUXAppKit.m,
 * libUXIos.m, libUXAndroid.c) so it is written once and compiled into each.  The definitions live in
 * the header on purpose: each shim is its own library and includes this exactly once, and the
 * functions are exported (not static) because the drivers call them by name.
 *
 * listDir's format is the panel's: one line per entry, "t<TAB>size<TAB>name\n", t = 'd' or 'f';
 * "." and ".." are left out (the panel draws its own ".." row).  Returns the entry count, or -1. */
#ifndef UX_POSIX_FS_H
#define UX_POSIX_FS_H
#include <dirent.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int ux_posix_listdir(const char* path, char* out, int cap)
{
    if (!path || !out || cap < 1) return -1;
    out[0] = 0;
    DIR* d = opendir(path);
    if (!d) return -1;
    int n = 0, used = 0;
    struct dirent* e;
    char full[4096];
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        snprintf(full, sizeof full, "%s/%s", path, e->d_name);
        struct stat st;
        int isDir = 0;
        unsigned long size = 0;
        if (stat(full, &st) == 0) {          /* follows links: a link to a folder is a folder */
            isDir = S_ISDIR(st.st_mode);
            size = isDir ? 0 : (unsigned long)st.st_size;
        }
        char line[1200];
        int len = snprintf(line, sizeof line, "%c\t%lu\t%s\n", isDir ? 'd' : 'f', size, e->d_name);
        if (len <= 0 || used + len >= cap) break;   /* full: list what fits, never overrun */
        memcpy(out + used, line, (size_t)len);
        used += len;
        out[used] = 0;
        n++;
    }
    closedir(d);
    return n;
}

int ux_posix_delete(const char* path)
{
    return path && unlink(path) == 0 ? 1 : 0;
}

int ux_posix_rename(const char* src, const char* dst)
{
    return src && dst && rename(src, dst) == 0 ? 1 : 0;
}

int ux_posix_copy(const char* src, const char* dst)
{
    if (!src || !dst) return 0;
    FILE* in = fopen(src, "rb");
    if (!in) return 0;
    FILE* out = fopen(dst, "wb");
    if (!out) { fclose(in); return 0; }
    char buf[8192];
    size_t got;
    int ok = 1;
    while ((got = fread(buf, 1, sizeof buf, in)) > 0)
        if (fwrite(buf, 1, got, out) != got) { ok = 0; break; }
    fclose(in);
    if (fclose(out) != 0) ok = 0;
    if (!ok) unlink(dst);
    return ok;
}
#endif
