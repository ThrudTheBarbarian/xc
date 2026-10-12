# The benchmark visualiser — a UXKit program that reads a contribution JSON,
# draws it, and moves contributions to and from the project's corpus.
#
#   make                  build for this host
#   make run              build and open an empty window (File ▸ Open to load one)
#   make run FILE=x.json  build and open one contribution
#   make selftest         build and check the model head-less against sample.json
#   make clean
#
# It builds against the UXKit *sources*, not the installed library, because it
# needs JSON, Http and Socket beside the toolkit: the toolkit's library and
# those standard-library modules each declare the Foundation classes, so they
# are compiled together in one translation unit here.  Point UXKIT at the
# UXKit source directory (the xcc-uxkit archive carries it; in a full checkout
# it is frameworks/uxkit).
#
#   make UXKIT=/path/to/uxkit

XCC   ?= xcc
UXKIT ?= ../../frameworks/uxkit
BUILD := build
OUT   := $(BUILD)/visualiser
OPT   ?= -O2

UNAME := $(shell uname -s)

# The shim rules below come first in the file; without this, plain `make` would
# build only the shim.
.DEFAULT_GOAL := all

ifeq ($(UNAME),Darwin)
# macOS: the AppKit driver crosses into Objective-C, so the toolkit ships a
# small shim (libUXAppKit.m) built with the system clang, linked in beside it.
# The toolkit's GL path uses the deprecated NSOpenGL APIs, which names hundreds
# of warnings on a current SDK; they are suppressed here so the build is quiet.
SHIM  := $(BUILD)/libUXAppKit.dylib
LINK  := -Xlinker $(SHIM) -framework Cocoa -framework OpenGL
ARCH  := arm64
EXT   :=
$(SHIM): $(UXKIT)/libUXAppKit.m
	@mkdir -p $(BUILD)
	cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
	   -Wno-deprecated-declarations -Wno-enum-conversion \
	   -install_name "$(CURDIR)/$(SHIM)" $(UXKIT)/libUXAppKit.m \
	   -framework Cocoa -framework OpenGL -o $(SHIM)
else ifeq ($(UNAME),Linux)
# Linux: the GTK driver's shim (libUXGtk.c) links GTK 4, which has to be on the
# machine that runs the program as well as the one that builds it.
SHIM  := $(BUILD)/libUXGtk.so
GTK   := $(shell pkg-config --cflags --libs gtk4)
LINK  := -Xlinker $(SHIM) $(GTK)
ARCH  := x86_64
EXT   :=
$(SHIM): $(UXKIT)/libUXGtk.c
	@mkdir -p $(BUILD)
	cc -shared -fPIC -o $(SHIM) $(UXKIT)/libUXGtk.c $(GTK)
else
# Windows: the Win32 driver is pure xc and reaches GDI and the user32 DLLs
# directly, so there is no shim to build.
SHIM  :=
LINK  :=
ARCH  := win64
EXT   := .exe
endif

$(OUT)$(EXT): Visualiser.xc Model.xc Chart.xc Net.xc $(SHIM)
	@mkdir -p $(BUILD)
	$(XCC) -A $(ARCH) -I $(UXKIT) -I . $(OPT) Visualiser.xc $(LINK) -o $@

.PHONY: all run selftest clean
all: $(OUT)$(EXT)

run: $(OUT)$(EXT)
	./$(OUT)$(EXT) $(FILE)

selftest: $(OUT)$(EXT)
	./$(OUT)$(EXT) --selftest sample.json

clean:
	rm -rf $(BUILD)
