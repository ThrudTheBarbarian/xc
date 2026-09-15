# Rocks — a GEM Resource Construction Set for macOS (AppKit / Objective-C).
#
#   make          build Rocks.app
#   make run      build and launch
#   make rockscli build the headless resource compiler (build/rockscli)
#   make clean

APP      := Rocks
BUNDLE   := build/$(APP).app
BIN      := $(BUNDLE)/Contents/MacOS/$(APP)
CLI      := build/rockscli

# main.m and rockscli.m each define main(), so neither app nor CLI gets both.
ALL_MSRCS := $(wildcard src/*.m)
SRCS     := $(filter-out src/rockscli.m,$(ALL_MSRCS))
CSRCS    := $(wildcard src/*.c)
OBJS     := $(patsubst src/%.m,build/obj/%.o,$(SRCS)) \
            $(patsubst src/%.c,build/obj/%.o,$(CSRCS))

# The CLI is the model + format + exporters, with no views or controllers.
CLI_OBJS := $(addprefix build/obj/,rockscli.o GModel.o GRsc.o GProject.o GImage.o \
                                   GExport.o rsc.o)

CC       := clang
CFLAGS   := -x objective-c -fobjc-arc -Wall -Wno-deprecated-declarations \
            -mmacosx-version-min=13.0 -O0 -g
CONLY    := -std=c11 -Wall -O0 -g
LDFLAGS  := -framework Cocoa -framework AppKit -framework Foundation \
            -framework CoreText -framework CoreGraphics

# The GEM desktop checkout supplies the theme, the UI font and the sample .rsc
# used by `make check`.  Set GEM_DIR in build.env (see build.env.template).
BUILD_ENV := $(wildcard ../../build.env)
build_env = $(if $(BUILD_ENV),$(shell sed -n 's/^$(1)=//p' $(BUILD_ENV)))
GEM_DIR   ?= $(call build_env,GEM_DIR)
THEME_SRC := $(GEM_DIR)/themes
FONT_SRC  := $(GEM_DIR)/fonts
.PHONY: all run clean rockscli check
all: $(BIN) $(BUNDLE)/Contents/Info.plist theme fonts $(CLI)

rockscli: $(CLI)

$(CLI): $(CLI_OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(CLI_OBJS) $(LDFLAGS) -o $@

# Export a real .rsc to C, then walk the generated tree and the original file in
# lockstep and diff every field — geometry, links, strings, TEDINFO, bitplanes.
# Compiling the output only proves it parses; this proves it carries the resource.
RSC_SAMPLE ?= $(GEM_DIR)/resources/desktop.rsc
check: $(CLI) $(BIN)
	@if [ ! -f "$(RSC_SAMPLE)" ]; then \
	    echo "check: no sample .rsc at '$(RSC_SAMPLE)' — pass RSC_SAMPLE=<file.rsc>"; \
	else \
	    mkdir -p build/check; \
	    ./$(CLI) "$(RSC_SAMPLE)" -o build/check/res --emit h,c >/dev/null && \
	    $(CC) -std=c11 -w -Isrc -Ibuild/check \
	        tests/export_check.c build/check/res.c src/rsc.c -o build/check/export_check && \
	    ./build/check/export_check "$(RSC_SAMPLE)" && \
	    ./$(BIN) --selftest >/dev/null && echo "  selftest  — OK" && \
	    ./$(BIN) --formtest && \
	    ./$(BIN) --clicktest "$(RSC_SAMPLE)"; \
	fi

# Bundle the Aristo2 theme into the app so it renders self-contained.  If it is
# not there the app is not shippable, so say so rather than quietly building one
# that only works on this machine (no absolute path is baked into the source).
theme:
	@if [ -d "$(THEME_SRC)/Aristo2" ]; then \
		rm -rf "$(BUNDLE)/Contents/Resources/themes/Aristo2"; \
		mkdir -p "$(BUNDLE)/Contents/Resources/themes"; \
		cp -R "$(THEME_SRC)/Aristo2" "$(BUNDLE)/Contents/Resources/themes/"; \
	elif [ ! -d "$(BUNDLE)/Contents/Resources/themes/Aristo2" ]; then \
		echo "warning: no theme at $(THEME_SRC)/Aristo2 — the app will fall back to plain GEM."; \
		echo "         set GEM_DIR in build.env to bundle it."; \
	fi

# Bundle the XTOS UI font.
fonts:
	@if [ -f "$(FONT_SRC)/AovelSansRounded.ttf" ]; then \
		mkdir -p "$(BUNDLE)/Contents/Resources/fonts"; \
		cp "$(FONT_SRC)/AovelSansRounded.ttf" "$(BUNDLE)/Contents/Resources/fonts/"; \
	fi

build/obj/%.o: src/%.m | build/obj
	$(CC) $(CFLAGS) -c $< -o $@

build/obj/%.o: src/%.c | build/obj
	$(CC) $(CONLY) -c $< -o $@

$(BIN): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(OBJS) $(LDFLAGS) -o $@

$(BUNDLE)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp Info.plist $@

build/obj:
	@mkdir -p build/obj

run: all
	@echo "launching $(BUNDLE)"
	@open $(BUNDLE)

clean:
	rm -rf build
