"""The C library as xc sees it: the functions a converted program may call
as natives on the host targets, with their xc signatures, the typedefs the
fake headers hand pycparser, and the few calls that need rewriting rather
than declaring (va_start's second argument, va_list forwarding).

Only the names a program uses are declared in its output.
"""
import c2xc as X

def _t(spec):
    """'i32', 'u8*', 'pointer', 'double', 'void', 'u64', 'i64', 'u8**'"""
    from c2xc import T, INT, FLT, PTR, VOID, VOIDP, BOOL
    spec = spec.strip()
    if spec == "void": return VOID
    if spec == "pointer": return VOIDP
    if spec == "bool": return BOOL
    if spec.endswith("*"): return PTR(_t(spec[:-1]))
    if spec in ("float",): return FLT(32)
    if spec == "double": return FLT(64)
    sign = spec[0] == "i"; bits = int(spec[1:])
    return INT(bits, sign)

def fn(ret, params, va=False):
    from c2xc import T
    return T("fn", ret=_t(ret), params=[_t(p) for p in params if p], varargs=va)

# name -> (return, [params], varargs)
_SPEC = {
    # stdio
    "printf":   ("i32", ["u8*"], True),   "fprintf": ("i32", ["pointer", "u8*"], True),
    "sprintf":  ("i32", ["u8*", "u8*"], True), "snprintf": ("i32", ["u8*", "u64", "u8*"], True),
    "puts": ("i32", ["u8*"]), "putchar": ("i32", ["i32"]), "fputs": ("i32", ["u8*", "pointer"]), "fputc": ("i32", ["i32", "pointer"]),
    "putc": ("i32", ["i32", "pointer"]), "getchar": ("i32", []), "getc": ("i32", ["pointer"]), "fgetc": ("i32", ["pointer"]),
    "fgets": ("u8*", ["u8*", "i32", "pointer"]), "fopen": ("pointer", ["u8*", "u8*"]), "fclose": ("i32", ["pointer"]),
    "fread": ("u64", ["pointer", "u64", "u64", "pointer"]), "fwrite": ("u64", ["pointer", "u64", "u64", "pointer"]),
    "fflush": ("i32", ["pointer"]), "fseek": ("i32", ["pointer", "i64", "i32"]), "ftell": ("i64", ["pointer"]), "rewind": ("void", ["pointer"]),
    "feof": ("i32", ["pointer"]), "ferror": ("i32", ["pointer"]), "remove": ("i32", ["u8*"]), "rename": ("i32", ["u8*", "u8*"]),
    "perror": ("void", ["u8*"]), "sscanf": ("i32", ["u8*", "u8*"], True), "fscanf": ("i32", ["pointer", "u8*"], True), "scanf": ("i32", ["u8*"], True),
    "ungetc": ("i32", ["i32", "pointer"]), "fileno": ("i32", ["pointer"]), "fdopen": ("pointer", ["i32", "u8*"]), "tmpfile": ("pointer", []),
    "setvbuf": ("i32", ["pointer", "u8*", "i32", "u64"]), "setbuf": ("void", ["pointer", "u8*"]),
    # stdlib
    "malloc": ("pointer", ["u64"]), "calloc": ("pointer", ["u64", "u64"]), "realloc": ("pointer", ["pointer", "u64"]), "free": ("void", ["pointer"]),
    "exit": ("void", ["i32"]), "_exit": ("void", ["i32"]), "abort": ("void", []), "atexit": ("i32", ["pointer"]),
    "atoi": ("i32", ["u8*"]), "atol": ("i64", ["u8*"]), "atof": ("double", ["u8*"]), "strtol": ("i64", ["u8*", "u8**", "i32"]),
    "strtoul": ("u64", ["u8*", "u8**", "i32"]), "strtoll": ("i64", ["u8*", "u8**", "i32"]), "strtod": ("double", ["u8*", "u8**"]),
    "rand": ("i32", []), "srand": ("void", ["u32"]), "random": ("i64", []), "srandom": ("void", ["u32"]),
    "getenv": ("u8*", ["u8*"]), "setenv": ("i32", ["u8*", "u8*", "i32"]), "system": ("i32", ["u8*"]),
    "qsort": ("void", ["pointer", "u64", "u64", "pointer"]), "bsearch": ("pointer", ["pointer", "pointer", "u64", "u64", "pointer"]),
    "abs": ("i32", ["i32"]), "labs": ("i64", ["i64"]), "llabs": ("i64", ["i64"]),
    # string
    "strlen": ("u64", ["u8*"]), "strcpy": ("u8*", ["u8*", "u8*"]), "strncpy": ("u8*", ["u8*", "u8*", "u64"]),
    "strcat": ("u8*", ["u8*", "u8*"]), "strncat": ("u8*", ["u8*", "u8*", "u64"]), "strcmp": ("i32", ["u8*", "u8*"]),
    "strncmp": ("i32", ["u8*", "u8*", "u64"]), "strcasecmp": ("i32", ["u8*", "u8*"]), "strncasecmp": ("i32", ["u8*", "u8*", "u64"]),
    "strchr": ("u8*", ["u8*", "i32"]), "strrchr": ("u8*", ["u8*", "i32"]), "strstr": ("u8*", ["u8*", "u8*"]),
    "strdup": ("u8*", ["u8*"]), "strndup": ("u8*", ["u8*", "u64"]), "strtok": ("u8*", ["u8*", "u8*"]), "strspn": ("u64", ["u8*", "u8*"]),
    "strcspn": ("u64", ["u8*", "u8*"]), "strpbrk": ("u8*", ["u8*", "u8*"]), "strerror": ("u8*", ["i32"]),
    "memcpy": ("pointer", ["pointer", "pointer", "u64"]), "memmove": ("pointer", ["pointer", "pointer", "u64"]),
    "memset": ("pointer", ["pointer", "i32", "u64"]), "memcmp": ("i32", ["pointer", "pointer", "u64"]), "memchr": ("pointer", ["pointer", "i32", "u64"]),
    "bzero": ("void", ["pointer", "u64"]), "bcopy": ("void", ["pointer", "pointer", "u64"]),
    # ctype
    "isalpha": ("i32", ["i32"]), "isdigit": ("i32", ["i32"]), "isalnum": ("i32", ["i32"]), "isspace": ("i32", ["i32"]),
    "isupper": ("i32", ["i32"]), "islower": ("i32", ["i32"]), "isprint": ("i32", ["i32"]), "ispunct": ("i32", ["i32"]),
    "isxdigit": ("i32", ["i32"]), "iscntrl": ("i32", ["i32"]), "isgraph": ("i32", ["i32"]), "toupper": ("i32", ["i32"]), "tolower": ("i32", ["i32"]),
    # math
    "sqrt": ("double", ["double"]), "sin": ("double", ["double"]), "cos": ("double", ["double"]), "tan": ("double", ["double"]),
    "atan": ("double", ["double"]), "atan2": ("double", ["double", "double"]), "exp": ("double", ["double"]), "log": ("double", ["double"]),
    "log10": ("double", ["double"]), "pow": ("double", ["double", "double"]), "fabs": ("double", ["double"]), "floor": ("double", ["double"]),
    "ceil": ("double", ["double"]), "fmod": ("double", ["double", "double"]), "hypot": ("double", ["double", "double"]),
    "asin": ("double", ["double"]), "acos": ("double", ["double"]), "sinh": ("double", ["double"]), "cosh": ("double", ["double"]), "tanh": ("double", ["double"]),
    "round": ("double", ["double"]), "trunc": ("double", ["double"]), "ldexp": ("double", ["double", "i32"]), "frexp": ("double", ["double", "i32*"]),
    "sqrtf": ("float", ["float"]), "fabsf": ("float", ["float"]), "floorf": ("float", ["float"]),
    # time / unistd / misc
    "time": ("i64", ["pointer"]), "clock": ("i64", []), "sleep": ("u32", ["u32"]), "usleep": ("i32", ["u32"]),
    "getpid": ("i32", []), "fork": ("i32", []), "setsid": ("i32", []), "clearerr": ("void", ["pointer"]), "read": ("i64", ["i32", "pointer", "u64"]), "write": ("i32", ["i32", "u8*", "i32"]), "close": ("i32", ["i32"]),
    "open": ("i32", ["u8*", "i32"], True), "unlink": ("i32", ["u8*"]), "lseek": ("i64", ["i32", "i64", "i32"]),
    "assert": ("void", ["i32"]),
    "times": ("i64", ["pointer"]), "sbrk": ("pointer", ["i64"]), "getpagesize": ("i32", []),
    "gettimeofday": ("i32", ["pointer", "pointer"]), "localtime": ("pointer", ["pointer"]), "gmtime": ("pointer", ["pointer"]),
    "strftime": ("u64", ["u8*", "u64", "u8*", "pointer"]), "ctime": ("u8*", ["pointer"]), "mktime": ("i64", ["pointer"]),
    "isatty": ("i32", ["i32"]), "dup": ("i32", ["i32"]), "dup2": ("i32", ["i32", "i32"]), "pipe": ("i32", ["i32*"]),
    "chdir": ("i32", ["u8*"]), "getcwd": ("u8*", ["u8*", "u64"]), "mkdir": ("i32", ["u8*", "u32"]), "rmdir": ("i32", ["u8*"]),
    "access": ("i32", ["u8*", "i32"]), "getuid": ("u32", []), "kill": ("i32", ["i32", "i32"]), "alarm": ("u32", ["u32"]),
    "strerror_r": ("i32", ["i32", "u8*", "u64"]), "memrchr": ("pointer", ["pointer", "i32", "u64"]),
    "fcntl": ("i32", ["i32", "i32"], True), "creat": ("i32", ["u8*", "u32"]), "stat": ("i32", ["u8*", "pointer"]), "fstat": ("i32", ["i32", "pointer"]),
    "lstat": ("i32", ["u8*", "pointer"]), "chmod": ("i32", ["u8*", "u32"]), "localtime_r": ("pointer", ["pointer", "pointer"]), "gmtime_r": ("pointer", ["pointer", "pointer"]),
    "asctime": ("u8*", ["pointer"]), "difftime": ("double", ["i64", "i64"]), "getopt": ("i32", ["i32", "u8**", "u8*"]),
    "signal": ("pointer", ["i32", "pointer"]), "raise": ("i32", ["i32"]), "setjmp": ("i32", ["pointer"]), "longjmp": ("void", ["pointer", "i32"]),
    "ftruncate": ("i32", ["i32", "i64"]), "fsync": ("i32", ["i32"]), "umask": ("u32", ["u32"]), "link": ("i32", ["u8*", "u8*"]), "symlink": ("i32", ["u8*", "u8*"]),
}
FUNCS = {}
for _n, _s in _SPEC.items():
    FUNCS[_n] = fn(_s[0], _s[1], _s[2] if len(_s) > 2 else False)

# C typedef names the fake headers leave as plain identifiers
TYPEDEFS = {
    "size_t": _t("u64"), "ssize_t": _t("i64"), "ptrdiff_t": _t("i64"), "intptr_t": _t("i64"), "uintptr_t": _t("u64"),
    "int8_t": _t("i8"), "uint8_t": _t("u8"), "int16_t": _t("i16"), "uint16_t": _t("u16"), "int32_t": _t("i32"), "uint32_t": _t("u32"),
    "int64_t": _t("i64"), "uint64_t": _t("u64"), "time_t": _t("i64"), "clock_t": _t("i64"), "off_t": _t("i64"), "pid_t": _t("i32"),
    "FILE": _t("i32"), "va_list": _t("u8"), "__builtin_va_list": _t("u8"), "wchar_t": _t("i32"), "bool": X.BOOL, "_Bool": X.BOOL,
    "u_char": _t("u8"), "u_short": _t("u16"), "u_int": _t("u32"), "u_long": _t("u64"), "uid_t": _t("u32"), "gid_t": _t("u32"), "mode_t": _t("u32"),
    "socklen_t": _t("u32"), "sig_atomic_t": _t("i32"), "jmp_buf": _t("pointer"), "DIR": _t("i32"),
}
VARS = {"errno": _t("i32"), "stdin": _t("pointer"), "stdout": _t("pointer"), "stderr": _t("pointer"), "optarg": _t("u8*"), "optind": _t("i32")}
# the symbol behind a libc variable on this host (darwin's stdio streams are __stdinp etc.)
import sys as _sys
VAR_SYMBOL = {"stdin": "__stdinp", "stdout": "__stdoutp", "stderr": "__stderrp"} if _sys.platform == "darwin" else {}
# reached through the run-time instead (private:xcc-bugs/25: an extern is a private copy)
RT_VARS = {"stdin": "c2xc_stdin", "stdout": "c2xc_stdout", "stderr": "c2xc_stderr", "optarg": "(*c2xc_optargp)", "optind": "(*c2xc_optindp)", "errno": "(*__error())"}
def var_decl(name):
    return "extern %s %s;" % (VARS[name].xc(), VAR_SYMBOL.get(name, name))

def decl(name, conv):
    t = FUNCS[name]
    ps = ", ".join("%s a%d" % (p.xc(), i) for i, p in enumerate(t.params)) if t.params else "void"
    if t.varargs: ps = (ps + ", ...") if t.params else "..."
    return "%s %s(%s);" % (t.ret.xc(), name, ps)

# ── rewrites: calls that are not plain natives ─────────────────────────────
def _va_start(conv, e, args):
    ap = conv.ex(args[0]); return "va_start(%s)" % ap, X.VOID
def _va_end(conv, e, args):
    ap = conv.ex(args[0]); return "va_end(%s)" % ap, X.VOID
def _va_arg(conv, e, args):
    # va_arg(ap, T) arrives as __c2xc_va_arg(ap, (T)0): the cast carries the type
    ap = conv.ex(args[0]); t = conv.type_of_decl(args[1].to_type)
    xt = t.xc()
    if t.is_int() and t.bits == 64: conv.warn(e, "va_arg of a 64-bit integer: xc has no intrinsic; read as u32")
    return "va_arg(%s, %s)" % (ap, xt), t
def _getopt(conv, e, args):
    conv.needs_rt = True
    return "c2xc_getopt(%s)" % ", ".join(conv.ex(a) for a in args), _t("i32")
def _assert(conv, e, args):
    c = conv.ex(args[0], ctx="cond")
    conv.needs_rt = True                         # c2xc_assert lives in the run-time
    return "c2xc_assert(%s)" % c, X.VOID
def _forward(base):
    # vsnprintf(buf, n, fmt, ap) where ap is only ever forwarded: the run-time's
    # xc formatter takes the tail (a C native cannot read an xc pack)
    def rw(conv, e, args):
        if conv.forward_only and isinstance(args[-1], X.c_ast.ID):
            conv.needs_rt = True
            head = [conv.ex(a, p if p.is_scalar() else None) for a, p in zip(args[:-1], FUNCS[base].params)]
            return "c2xc_%s(%s, ...)" % (base, ", ".join(head)), FUNCS[base].ret
        conv.warn(e, "%s with a va_list that is also read: not expressible in xc" % base)
        return "0", X.I32
    return rw
def _va_start_fwd(conv, e, args):
    if conv.forward_only: return "(void)0", X.VOID
    return _va_start(conv, e, args)
def _va_end_fwd(conv, e, args):
    if conv.forward_only: return "(void)0", X.VOID
    return _va_end(conv, e, args)
REWRITE = {"assert": _assert, "va_start": _va_start_fwd, "va_end": _va_end_fwd, "__c2xc_va_arg": _va_arg, "__builtin_va_start": _va_start_fwd, "__builtin_va_end": _va_end_fwd,
           "vsnprintf": _forward("snprintf"), "vsprintf": _forward("sprintf"), "vprintf": _forward("printf"), "vfprintf": _forward("fprintf")}
