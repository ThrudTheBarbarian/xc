# Rocks.app — the resource editor, on the XT.
#
# An APPLICATION: it #imports <Xtg> and LINKS libXG.so.  It does not compile the
# toolkit in.  That is the whole proof — a real app against a real shared library.
XTC    ?= xtc
BUILD_ENV := $(wildcard ../../../build.env)
build_env = $(if $(BUILD_ENV),$(shell sed -n 's/^$(1)=//p' $(BUILD_ENV)))
LOADER ?= $(call build_env,LOADER)
GEMLIB ?= $(or $(call build_env,GEMLIB),$(LOADER)/build)
XTG    ?= ../XG
ARCH   ?= arm9

all: Rocks.app test_rocks.app

Rocks.app: Rocks.xt RocksApp.xt $(XTG)/libXG.so
	$(XTC) -A $(ARCH) -I . -I $(XTG) -L $(XTG) -L $(GEMLIB) Rocks.xt -o $@

test_rocks.app: test_rocks.xt RocksApp.xt $(XTG)/libXG.so
	$(XTC) -A $(ARCH) -I . -I $(XTG) -L $(XTG) -L $(GEMLIB) test_rocks.xt -o $@

$(XTG)/libXG.so:
	$(MAKE) -C $(XTG) lib

# ---- install: put Rocks where BOTH media can find it ----------------------------
# The loader's romfs-overlay is generic — anything under romfs-overlay/X appears at /X in
# the romfs — and the loader's `sdstage` also ships romfs-overlay/bin/* to the card's
# /OS/bin. So one install target serves qemu AND the board: `rocks` becomes a command.
#
# libXG.so goes with it. A client and its library must be deployed TOGETHER — ship one
# without the other and the app dies at load, which is exactly what the version gate in
# xtg/VERSION now catches by name instead of as a PC=0 jump.
install: Rocks.app
	@mkdir -p $(LOADER)/romfs-overlay/bin $(LOADER)/romfs-overlay/Library
	cp $(XTG)/libXG.so $(LOADER)/romfs-overlay/Library/
	cp Rocks.app        $(LOADER)/romfs-overlay/bin/rocks

# See it in qemu: 200x120, dumped to the console as ASCII art (there is no display device
# in qemu — gemd's plane is DDR that the PL compositor scans on real hardware).
run: install
	$(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/Rocks.app

# See it on the BOARD, on real HDMI. `rocks` is then a command at the board's shell.
board: install
	$(MAKE) -C $(LOADER) sdpush

clean: ; rm -f Rocks.app test_rocks.app
.PHONY: all run clean install board
