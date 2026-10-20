# tools/mac_run.sh -- sourced by the macOS gates that open windows (AppKit, GTK, Rocks).
#
#   ux_mac_run [-t seconds] [NAME=value ...] <binary> [args]
#
# runs a test program here, or, when UX_MAC_GUI_HOST names another Mac (build.env), on that Mac,
# so its windows open on that Mac's screen and not on this one.  UX_MAC_GUI_HOST=local runs it here
# for once (an empty value would not override build.env).
#
# -t ends the run after that many seconds, on whichever Mac it runs.  NAME=value pairs are set for
# the program (values without spaces).  On another Mac the binary's directory is copied there and
# the files the program writes in it come back (a test may leave files for the script to read); the
# NAME=value pairs and the exported UX_* variables go with it, with that directory's path rewritten.
# The binary finds its shim (libUXAppKit/libUXGtk) by DYLD_LIBRARY_PATH; a GTK test needs Homebrew's
# gtk4 there at this Mac's version or a later one.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

ux_mac_run() {
    _secs=
    _vars=
    if [ "$1" = -t ]; then
        _secs=$2
        shift 2
    fi
    while :; do
        case "$1" in
            [A-Za-z_]*=*) _vars="$_vars $1"; shift ;;
            *) break ;;
        esac
    done
    _bin=$1
    shift
    if [ -z "${UX_MAC_GUI_HOST:-}" ] || [ "$UX_MAC_GUI_HOST" = local ]; then
        if [ -n "$_secs" ]; then
            env $_vars timeout "$_secs" "$_bin" "$@"
        else
            env $_vars "$_bin" "$@"
        fi
        return
    fi
    _dir=$(dirname "$_bin")
    _rdir=$(ssh -o BatchMode=yes "$UX_MAC_GUI_HOST" 'mktemp -d') || { echo "FAIL: $UX_MAC_GUI_HOST unreachable"; return 1; }
    scp -qr "$_dir/." "$UX_MAC_GUI_HOST:$_rdir/"
    _envs=$( (env | grep '^UX_' | grep -v '^UX_MAC_GUI_HOST=' || true; for _v in $_vars; do echo "$_v"; done) |
        sed -e "s|$_dir|$_rdir|g" -e "s/'/'\\\\''/g" -e "s/^\([^=]*\)=\(.*\)$/\1='\2'/" | tr '\n' ' ')
    _run="env $_envs DYLD_LIBRARY_PATH=$_rdir ./$(basename "$_bin") $*"
    if [ -n "$_secs" ]; then
        # no timeout(1) on a stock Mac: a watchdog ends the program, and its status is the program's
        _run="$_run & p=\$!; (sleep $_secs; kill \$p 2>/dev/null) & w=\$!; wait \$p; r=\$?; kill \$w 2>/dev/null; exit \$r"
    fi
    _rc=0
    ssh -o BatchMode=yes "$UX_MAC_GUI_HOST" "cd $_rdir && touch .ux_mac_run && sleep 1 && $_run" || _rc=$?
    # only what the program wrote: the rest is already here, and may have changed here since
    ssh -o BatchMode=yes "$UX_MAC_GUI_HOST" "cd $_rdir && find . -type f -newer .ux_mac_run | tar cf - -T -" 2>/dev/null |
        (cd "$_dir" && tar xf - 2>/dev/null) || true
    ssh -o BatchMode=yes "$UX_MAC_GUI_HOST" "rm -rf $_rdir" || true
    return $_rc
}
