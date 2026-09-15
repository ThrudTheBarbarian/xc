# hostgem/Makefile — the UXKit-on-host-GEM/SDL port.
#
# Milestone 0 (DONE): the host syscall shim + its IPC/shm rendezvous unit test.
# Milestone 1 (in progress): a host build of gemd (the portable GEM server) over the shim.
BUILD_ENV := $(wildcard ../../../build.env)
build_env = $(if $(BUILD_ENV),$(shell sed -n 's/^$(1)=//p' $(BUILD_ENV)))
GEM ?= $(call build_env,GEM_DIR)
CFLAGS := -O0 -g -Wall -Wno-implicit-function-declaration -I. -I$(GEM) -I$(GEM)/gemd
TMP    := $(HOME)/.cache

.PHONY: test probe clean client events events-full gem gem-build settings
# Milestone 0: prove the transport (Unix-socket services + POSIX-shm surfaces) works on macOS.
test: xtos_host.c test_shim.c xtos_host.h
	cc -O2 -Wall xtos_host.c test_shim.c -o /tmp/xg_test_shim && /tmp/xg_test_shim

# Milestone 1: build the portable GEM server (core + gemd + client) into a host binary over the
# shim, run it headless, and confirm it composites a desktop into the framebuffer buffer.
gemd:
	bash build_gemd.sh && /tmp/xg_hostgemd/host_gemd

clean: ; rm -f /tmp/xg_test_shim; rm -rf /tmp/xg_hostgemd

# Milestone 2: the UXKit kitchen-sink as a native client of the host gemd; asserts the window composites.
client: ; bash run_client.sh

# Milestone 3: inject a synthetic click into the host gemd; assert UXKit fires the button's action.
events: ; bash run_events.sh

# Broader coverage: drive table selection, text-field typing, and button actions by injection.
events-full: ; bash run_events_full.sh

# Settings: UXKeyValueStore over the XTOS SQLite registry, written by one process and read by the
# next.  No gemd and no window — the settings seam is the only part of the AES that needs neither.
settings:  ; bash run_settings.sh

# Milestone 4: the UXKit kitchen-sink in a live, clickable SDL window (needs SDL2).  `make gem-build`
# just compiles + links the SDL harness (headless/CI check); `make gem` opens the window.
gem:       ; bash run_gem.sh
gem-build: ; bash run_gem.sh --build-only
