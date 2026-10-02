#!/bin/sh
# run_gtk_panels.sh -- the `gtk-panels` gate: GTK 4's own file, colour and font dialogs behind
# UXOpenPanel / UXSavePanel and the pickers, each answered through the REAL dialog on the Linux
# host under Xvfb (test_gtk_panels.xc).  Skips cleanly when the host is unreachable.
exec sh "$(cd "$(dirname "$0")" && pwd)/run_gtk_linux.sh" test_gtk_panels
