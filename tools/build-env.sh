# tools/build-env.sh: load machine-specific settings.
#
# Source it from a script:
#
#   _root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
#   [ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
#
# It reads build.env at the repository root, if present, and exports each
# non-empty value that is not already set in the environment. See
# build.env.template for the variables.

_xc_env_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null \
    || git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$_xc_env_root" ] && [ -f "$_xc_env_root/build.env" ]; then
    while IFS= read -r _xc_line || [ -n "$_xc_line" ]; do
        case "$_xc_line" in
            ''|'#'*) continue ;;
        esac
        _xc_name=${_xc_line%%=*}
        _xc_value=${_xc_line#*=}
        case "$_xc_name" in
            *[!A-Za-z0-9_]*|[0-9]*|'') continue ;;
        esac
        [ -n "$_xc_value" ] || continue
        eval "_xc_current=\${$_xc_name:-}"
        if [ -z "$_xc_current" ]; then
            export "$_xc_name=$_xc_value"
        fi
    done < "$_xc_env_root/build.env"
fi
unset _xc_env_root _xc_line _xc_name _xc_value _xc_current
