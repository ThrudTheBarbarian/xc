#!/bin/sh
# run_gtk_outline.sh -- the `gtk-outline` gate: UXOutlineView realized as a real GTK tree
# (GtkColumnView over a GtkTreeListModel) on the Linux host under Xvfb (test_gtk_outline.xc).
# Skips cleanly when the host is unreachable.
exec sh "$(cd "$(dirname "$0")" && pwd)/run_gtk_linux.sh" test_gtk_outline
