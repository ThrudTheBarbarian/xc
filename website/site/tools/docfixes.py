"""docfixes.py — rewrites of version history the patterns in docversions.py
cannot make: prose that says what an older release did ("up to 0.71 the static
ELF is the default"). Each pair is exact text, after the automatic strip, and
its replacement; a tree that lacks the text is untouched, so the list applies
to the current tree and to every release's tree alike. Add a pair whenever
`docversions.py strip --check` or a snapshot reports a mention left.
"""
FIXES = [
    # tutorials
    (''':::note[Android on Windows before 0.75]
In 0.74 the Android build failed on Windows with "cannot create a signing key":
the key generator read `/dev/urandom`, which Windows does not have. The key is generated on Windows too. With 0.74, build the APK on a Mac or Linux
machine, or pass a key made there with `-Flags "--sign-key C:\\path\\android-debug.key.raw"`.
:::

''', ''),
    ('''You need xcc 0.74 or later, `make`, and UXKit installed in the third-party
tree, `/opt/xcc/3p/uxkit/`, from the
[UXKit library archive](/compiler/downloads/#uxkit-library). All six
programs run with 0.75; with 0.74 the iOS and Android ones build but do not
run, because of how their libraries were stamped and named
([Changelog](/compiler/downloads/changelog/)).''', '''You need xcc, `make`, and UXKit installed in the third-party tree,
`/opt/xcc/3p/uxkit/`, from the
[UXKit library archive](/compiler/downloads/#uxkit-library).'''),
    ("# libUXKit.dylib. Needs xcc 0.75 for the simulator library's platform stamp.", "# libUXKit.dylib."),
    ("""# is the activity the system starts, and it loads the program. Needs xcc 0.75
# for the library names the APK records.""", "# is the activity the system starts, and it loads the program."),
    ("a Mac with a booted iPhone simulator (0.75) |", "a Mac with a booted iPhone simulator |"),
    ("a device or emulator visible to `adb` (0.75) |", "a device or emulator visible to `adb` |"),
    ("`doc-examples` gate compiles it. You need xcc 0.74 or later. If you", "`doc-examples` gate compiles it. If you"),
    ("You need xcc 0.74 or later, unpacked from", "You need xcc, unpacked from"),
    ("You need xcc 0.74 or later on your `PATH`", "You need xcc on your `PATH`"),
    ("You need xcc 0.7 or later and the repository's `apps/rocks`.", "You need xcc and the repository's `apps/rocks`."),
    # rocks
    ('''page works on macOS. On Linux (GTK) and Windows it works. In a browser
it works from 0.71 too, except the right-click menu and dropping files onto the
window; use Delete on the toolbar instead.''', '''page works on macOS, on Linux (GTK) and on Windows. In a browser it works
too, except the right-click menu and dropping files onto the window; use
Delete on the toolbar instead.'''),
    # compiler overview and usage
    ("a glibc ELF that loads system libraries (from 0.72; up to 0.71, with `-dynamic`); with `-static`, a static ELF over musl (up to 0.71, the default)",
     "a glibc ELF that loads system libraries; with `-static`, a static ELF over musl"),
    (" With `-static`, a static ELF over musl that runs on any distribution. (From 0.72; up to 0.71 the static ELF is the default and `-dynamic`, gives the glibc one.) |",
     " With `-static`, a static ELF over musl that runs on any distribution. |"),
    ("This is the default and `-dynamic` only names it; up to 0.71 the default is the static musl link. Still linked",
     "This is the default and `-dynamic` only names it. Still linked"),
    ("A library built with `--emit-lib` follows the same rule (see `--emit-lib`); up to 0.72, executables only. |",
     "A library built with `--emit-lib` follows the same rule (see `--emit-lib`). |"),
    ("It may be given more than once, one library each time; up to 0.72 only the last one is stored. |",
     "It may be given more than once, one library each time. |"),
    ("built for SSE2 and for AVX2, and from 0.71 for AVX-512 too, and the program", "built for SSE2, AVX2 and AVX-512, and the program"),
    ("`mimalloc` is `-A x86_64` only, and from 0.72 needs `-static`:", "`mimalloc` is `-A x86_64` only, and needs `-static`:"),
    ("for lldb and gdb (from 0.74; arm64, x86-64 and win64).", "for lldb and gdb (arm64, x86-64 and win64)."),
    # par
    ("on the CPU's threads, and from 0.7 on the GPU (Metal, CUDA, and from 0.72 Vulkan and WebGPU).",
     "on the CPU's threads and on the GPU (Metal, CUDA, Vulkan and WebGPU)."),
    ("[Independent work items](#independent-work-items)); from 0.8.1 the same holds", "[Independent work items](#independent-work-items)); the same holds"),
    ('''alone or in arrays, are exact on every Vulkan GPU, and from 0.73 they can be
  reduced there and through WebGPU too (up to 0.72 such a block runs on the
  CPU).''', '''alone or in arrays, are exact on every Vulkan GPU, and they can be reduced
  there and through WebGPU too.'''),
    ('''converted to and from `float` there too, with the CPU's results (up to 0.72
  such a block runs on the CPU). A block''', "converted to and from `float` there too, with the CPU's results. A block"),
    ("[Which device](#which-device)); up to 0.74 it used CUDA.", "[Which device](#which-device))."),
    ("other; from 0.8.1 a CUDA card pins", "other; a CUDA card pins"),
    ("**Resident data.** From 0.8.1 a CUDA card also keeps", "**Resident data.** A CUDA card also keeps"),
    ("**Most arrays need no qualifier.** From 0.8.1 the runtime keeps", "**Most arrays need no qualifier.** The runtime keeps"),
    ("round `+`, `-` and `*` exactly but not division or square roots; from 0.73 a\nblock", "round `+`, `-` and `*` exactly but not division or square roots; a\nblock"),
    ("except that from 0.72 the block's goal also holds", "except that the block's goal also holds"),
    ("`XC_PAR=gpus` (from 0.8: every GPU, tiled),\n  `XC_PAR=all` (from 0.8: every GPU and the CPU)", "`XC_PAR=gpus` (every GPU, tiled),\n  `XC_PAR=all` (every GPU and the CPU)"),
    ('for every block without its own choice; from 0.8 `"gpus"` and `"all"` too;', 'for every block without its own choice; `"gpus"` and `"all"` too;'),
    ("and `par = …` for every block without its own; from 0.8 `gpus`\n  and `all` as well.", "and `par = …` for every block without its own; `gpus`\n  and `all` as well."),
    ("the hardware key, and from 0.8\nthe tiles", "the hardware key, and\nthe tiles"),
    ("so its results are the CPU's (up to\n0.72 such a block runs on the CPU).", "so its results are the CPU's."),
    ("does this by itself (from\n0.8.1). Both sides", "does this by itself. Both sides"),
    ("which no test at compile time can rule out. From\n0.8.1 the runtime checks", "which no test at compile time can rule out. The\nruntime checks"),
    # API
    (''':::note[Upgrading from 0.64]
0.64's `standard` used the text file `$HOME/.config/xcc/<name>.conf` on every
platform. Where that file exists and the new one does not, it is
read, and the next [`save`](#save) writes to the new location.
:::''', ''':::note[An older settings file]
Where the text file `$HOME/.config/xcc/<name>.conf` exists, from a program
built when `standard` used it on every platform, and the platform's own store
does not, the file is read, and the next [`save`](#save) writes to the
platform's store.
:::'''),
    ('''or `nan`. (Before 0.72 a float went through `float` and
`i32` and printed values past 2³¹ and the non-finite ones wrongly.)''', "or `nan`."),
    ('''`-dynamic` writes a glibc executable that loads GTK 4 and the other libraries at
run time (from 0.72 that is the default, and `-dynamic` may be
left out), and''', '''A glibc executable, the default (`-dynamic` names it), loads GTK 4 and the other
libraries at run time, and'''),
    ('''follows from one property: **there is no inflation step**. Until 0.7 this
class was `UXRsc`; [`UXRsc`](/compiler/api/uxkit/uxrsc/) is now the loader for
every backend, GEM included,''', '''follows from one property: **there is no inflation step**.
[`UXRsc`](/compiler/api/uxkit/uxrsc/) is the loader for every backend, GEM
included,'''),
    ("**UXNB** chunk (v2, and from 0.7 v3)", "**UXNB** chunk (v2 or v3)"),
    ("drag. On AppKit, and from 0.71 on GTK, Windows and", "drag. On AppKit, GTK, Windows and"),
    ("keep it. On AppKit, and from 0.71 on GTK, Windows and", "keep it. On AppKit, GTK, Windows and"),
    ("window or been dropped. On AppKit, and from 0.71 on\nGTK, Windows and", "window or been dropped. On AppKit,\nGTK, Windows and"),
    ("Off by default. On AppKit, and from\n0.71 on GTK, Windows", "Off by default. On AppKit, GTK, Windows"),
    ("On AppKit, and on GTK and Windows from\n0.71.\n", "On AppKit, GTK and Windows.\n"),
    ("`UXComboBox`, and from\n0.75 `UXTextView`", "`UXComboBox`,\n`UXTextView`"),
    ("On AppKit, and on every backend from\n0.71.\n", "On every backend.\n"),
    ("""follows from one property: **there is no inflation step**. Until 0.7 this
class was `UXNib`; [`UXNib`](/compiler/api/uxkit/uxnib/) is now the loader for
every backend, GEM included,""", """follows from one property: **there is no inflation step**.
[`UXNib`](/compiler/api/uxkit/uxnib/) is the loader for every backend, GEM
included,"""),
    ("on the CPU's threads, and from 0.7 on the GPU.", "on the CPU's threads and on the GPU."),
    # landing
    ("native Linux executables. From 0.72 they are linked dynamically", "native Linux executables, linked dynamically"),
]


def apply(text):
    for old, new in FIXES:
        if old in text:
            text = text.replace(old, new)
    return text
