#!/bin/sh
# tools/win_desktop_run.sh <exe> [seconds] -- run a Windows program in the logged-in desktop session of
# the Windows machine UX_WIN_HOST (build.env), not in ssh's own session, which has no desktop: window
# painting and GL need one.  The program runs as an interactive scheduled task in the user's home
# folder, so files it writes there stay for the caller to fetch with scp; its output comes back here.
# Its window shows on that desktop while it runs.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
exe=$1; wait=${2:-90}
host=${UX_WIN_HOST:?set UX_WIN_HOST in build.env}
name=$(basename "$exe")
scp -q "$exe" "$host:uxrun_$name"
ssh -o BatchMode=yes "$host" "
\$d = \$env:USERPROFILE
Remove-Item \"\$d\\uxrun_out.txt\",\"\$d\\uxrun_done.txt\" -ErrorAction SilentlyContinue
\$cmd = 'cmd /c cd /d ' + \$d + ' && uxrun_$name > uxrun_out.txt 2>&1 & echo done > uxrun_done.txt'
schtasks /create /tn uxrun /tr \$cmd /sc once /st 23:59 /it /f | Out-Null
schtasks /run /tn uxrun | Out-Null
\$t = 0
while (-not (Test-Path \"\$d\\uxrun_done.txt\") -and \$t -lt $wait) { Start-Sleep 1; \$t++ }
Get-Content \"\$d\\uxrun_out.txt\" -ErrorAction SilentlyContinue
if (-not (Test-Path \"\$d\\uxrun_done.txt\")) { 'TIMEOUT' }
schtasks /delete /tn uxrun /f | Out-Null
Remove-Item \"\$d\\uxrun_$name\",\"\$d\\uxrun_out.txt\",\"\$d\\uxrun_done.txt\" -ErrorAction SilentlyContinue
"
