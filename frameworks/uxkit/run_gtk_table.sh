#!/bin/sh
# run_gtk_table.sh -- the `gtk-table` gate: UXTableView realized as a real GtkColumnView on the
# Linux host under Xvfb (test_gtk_table.xc).  Skips cleanly when the host is unreachable.
exec sh "$(cd "$(dirname "$0")" && pwd)/run_gtk_linux.sh" test_gtk_table
