CC  = clang
CP  = cp -f

UNAME_S := $(shell uname -s)
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0)

ifeq ($(UNAME_S),Darwin)
  PLATFORM_OBJCFLAGS = -fmodules -Wnullability-completeness
  LDFLAGS            = -framework Foundation
else
  # Linux — GNUstep; gnustep-config must be on PATH
  ifeq ($(shell which gnustep-config 2>/dev/null),)
    $(error gnustep-config not found. Install gnustep-devel (apt) or gnustep-make (dnf))
  endif
  PLATFORM_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks \
                       -include src/xtc/support/dispatch_compat.h \
                       $(shell gnustep-config --objc-flags)
  LDFLAGS            = $(shell gnustep-config --base-libs)
endif

VERSION_DEF  = -DXTC_VERSION='"$(VERSION)"'

# The build identity, so "is the fix actually in this install?" is answerable
# without running a repro — which was the only way to answer it before, and it
# came up often enough to be worth a rule.
#
# It goes in a GENERATED HEADER rather than a -D in OBJCFLAGS, because that
# define is global: putting a commit id there would rebuild all ~100 sources on
# every commit. Only the file that prints it includes this.
#
# Written via .tmp + cmp so the header's mtime moves ONLY when its contents
# change — otherwise every `make` would touch it and rebuild that file anyway.
# The commit DATE is used rather than the build time for the same reason: a
# wall-clock stamp changes on every build and would defeat the guard.
BUILD_ID_H = build/build-id.h
# `all` stays the default goal EXPLICITLY. The rules just below are the first
# targets in this file, and make takes the first target it sees as the default
# — so adding them silently made plain `make` build nothing at all, which looks
# exactly like "everything is up to date". Pinning it means the next rule added
# up here cannot repeat that.
.DEFAULT_GOAL := all
.PHONY: FORCE
FORCE:
$(BUILD_ID_H): FORCE
	@mkdir -p build
	@id=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown); \
	 git diff --quiet 2>/dev/null || id="$$id-dirty"; \
	 when=$$(git log -1 --format=%cd --date=format:'%Y-%m-%d' 2>/dev/null || echo unknown); \
	 printf '#define XTC_BUILD_ID "%s"\n#define XTC_BUILD_DATE "%s"\n' "$$id" "$$when" \
	   > $(BUILD_ID_H).tmp; \
	 if cmp -s $(BUILD_ID_H).tmp $(BUILD_ID_H) 2>/dev/null; then rm -f $(BUILD_ID_H).tmp; \
	 else mv $(BUILD_ID_H).tmp $(BUILD_ID_H); fi

# The harnesses written in ObjC cannot source tools/hostarch.sh, so the bin
# directory reaches them the only way it can: as a define. Without it they
# hardcode ./bin/osx and every fixture fails rc=-1 on Linux, where the binaries
# are in bin/linux — which is exactly how `make test` failed on the CI box.
BIN_DIR_DEF  = -DXC_BIN_DIR='"$(BIN_DIR)"'

OBJCFLAGS    = -fobjc-arc -Wall -Wextra -Wshadow \
               -std=gnu11 -Wno-unused-parameter \
               -Wno-objc-designated-initializers $(VERSION_DEF) $(BIN_DIR_DEF) \
               $(PLATFORM_OBJCFLAGS)
XTC_INCLUDES = $(shell find src/xtc -type d -exec echo -I {} \;) -Ibuild
src/xtc/main.o: $(BUILD_ID_H)
XTA_INCLUDES = $(shell find src/xta -type d -exec echo -I {} \;)
# -MMD  emit a .d depfile alongside each .o listing the headers it
#       included transitively (system headers excluded via the second
#       M). -MP adds phony targets for each header so that removing a
#       header doesn't cause "no rule to make target" errors.
# Without this, incremental builds miss header-only changes — e.g.
# removing an enum value from XTTokenType.h leaves stale .o files
# linked against the old enum layout, producing bizarre runtime
# failures that don't clear until `make clean`. This actually bit us
# during the delete-keyword removal.
DEPFLAGS     = -MMD -MP
CFLAGS       = $(OBJCFLAGS) $(DEPFLAGS) $(XTC_INCLUDES) $(XTA_INCLUDES)

# Built binaries land in a per-platform subdirectory so macOS and
# Linux builds can coexist in the same working tree without
# stepping on each other's object artefacts.
ifeq ($(UNAME_S),Darwin)
  BIN_DIR = bin/osx
else
  BIN_DIR = bin/linux
endif

# ── xtc + helpers — source groups for the front-end / back-end split.
# Each binary links only the groups it needs (Stage 8c). The first set
# is "still pick up every .m for the .o build rule"; the per-binary
# link lines below select subsets.
XTC_SRCS = $(filter-out src/xtc/net/XTHttps.m src/xtc/sign/XTAscApi.m, \
               $(shell find src/xtc -name '*.m'))
XTC_OBJS = $(XTC_SRCS:.m=.o)
XTA_LIB_SRCS = $(filter-out src/xta/main.m, $(shell find src/xta -name '*.m'))
XTA_LIB_OBJS = $(XTA_LIB_SRCS:.m=.o)

# Source-group object lists. Each binary's link line is the union of
# the groups it needs — no more "link everything" superset.
GRP_TYPES      = $(patsubst %.m,%.o,$(shell find src/xtc/types         -name '*.m'))
GRP_AST        = $(patsubst %.m,%.o,$(shell find src/xtc/ast           -name '*.m'))
GRP_LEXER      = $(patsubst %.m,%.o,$(shell find src/xtc/lexer         -name '*.m'))
# Source-location class — used by diagnostics + backends, not just the lexer.
GRP_SRCLOC     = src/xtc/lexer/XTSourceLocation.o
GRP_PARSER     = $(patsubst %.m,%.o,$(shell find src/xtc/parser        -name '*.m'))
GRP_PREPROC    = $(patsubst %.m,%.o,$(shell find src/xtc/preprocessor  -name '*.m'))
GRP_SEMA       = $(patsubst %.m,%.o,$(shell find src/xtc/sema          -name '*.m'))
GRP_DIAG       = $(patsubst %.m,%.o,$(shell find src/xtc/diagnostics   -name '*.m'))
GRP_DWARF      = $(patsubst %.m,%.o,$(shell find src/xtc/dwarf         -name '*.m'))
GRP_SUPPORT    = $(patsubst %.m,%.o,$(shell find src/xtc/support       -name '*.m'))
GRP_IR_FULL    = $(patsubst %.m,%.o,$(shell find src/xtc/ir            -name '*.m'))
# XTIRLowering ties the IR to the AST — only the frontend needs it.
GRP_IR         = $(filter-out src/xtc/ir/XTIRLowering.o, $(GRP_IR_FULL))
GRP_CG_SHARED  = src/xtc/codegen/XTLabelGenerator.o src/xtc/codegen/XTHomingAllocator.o src/xtc/codegen/XTAggInitRelay.o
GRP_CG_XT6502  = $(patsubst %.m,%.o,$(shell find src/xtc/codegen/xt6502 -name '*.m'))
GRP_CG_ARM64   = $(patsubst %.m,%.o,$(shell find src/xtc/codegen/arm64  -name '*.m'))
GRP_CG_ARM9    = $(patsubst %.m,%.o,$(shell find src/xtc/codegen/arm9   -name '*.m'))
GRP_CG_M68K    = $(patsubst %.m,%.o,$(shell find src/xtc/codegen/m68k   -name '*.m'))
GRP_CG_X8664   = $(patsubst %.m,%.o,$(shell find src/xtc/codegen/x86_64 -name '*.m'))
GRP_CG_WASM32  = $(patsubst %.m,%.o,$(shell find src/xtc/codegen/wasm32 -name '*.m'))
GRP_DRV_CORE   = src/xtc/driver/XTCommandLineOptions.o \
                 src/xtc/driver/XTMemoryModel.o \
                 src/xtc/driver/XTLinkerScriptParser.o \
                 src/xtc/driver/XTBankDescriptor.o \
                 src/xtc/driver/XTCloakedRegion.o
GRP_DRV_NEWIR  = src/xtc/driver/XTCompilerDriver.o \
                 src/xtc/driver/XTDesignableSynthesis.o \
                 src/xtc/driver/XTInterfaceSerializer.o \
                 src/xtc/driver/XTInterfaceImporter.o
GRP_RUNTIME_EM = src/xtc/driver/XTIRRuntimeEmitter.o

XTC_BIN  = $(BIN_DIR)/xcc

# ── xta (standalone assembler) ───────────────────────────────────────
XTA_SRCS = $(shell find src/xta -name '*.m')
XTA_OBJS = $(XTA_SRCS:.m=.o)
XTA_BIN  = $(BIN_DIR)/xcc-as
# Driver value/parser classes the standalone xta links so `-L` can read a
# layout file (the canonical XTLinkerScriptParser → XTMemoryModel path the
# in-process driver also uses). These are leaf classes — no compiler deps.
# XTCommandLineOptions comes along for resolveSupportRoot: — the assembler
# finds its symbol tables through the SAME search the compiler uses, rather
# than a private copy that could disagree about which tree is authoritative.
XTA_MODEL_OBJS = src/xtc/driver/XTLinkerScriptParser.o \
                 src/xtc/driver/XTMemoryModel.o \
                 src/xtc/driver/XTBankDescriptor.o \
                 src/xtc/driver/XTCloakedRegion.o \
                 src/xtc/driver/XTCommandLineOptions.o \
                 src/xtc/diagnostics/XTDiagnosticEngine.o \
                 src/xtc/lexer/XTSourceLocation.o

# ── xtc-fe (IR-emitting frontend) ────────────────────────────────────
# Stage 8b of the split: takes .xc → emits .ir text (via XTIRPrinter).
XTC_FE_MAIN = src/xtc-fe/main.m
XTC_FE_OBJ  = $(XTC_FE_MAIN:.m=.o)
XTC_FE_BIN  = $(BIN_DIR)/xcc-fe

# ── xtcg-6502 (IR → 6502 asm/xex code generator) ────────────────────
# Per-arch backend binary — Stage 8a of the front-end / back-end
# split. Reuses the same xtc object set (sans xtc/main.o) for now;
# Stage 8c trims it down once the dispatcher is wired up.
XTCG_6502_MAIN = src/xtcg-6502/main.m
XTCG_6502_OBJ  = $(XTCG_6502_MAIN:.m=.o)
XTCG_6502_BIN  = $(BIN_DIR)/xcc-cg-6502

XTCG_ARM64_MAIN = src/xtcg-arm64/main.m
XTCG_ARM64_OBJ  = $(XTCG_ARM64_MAIN:.m=.o)
XTCG_ARM64_BIN  = $(BIN_DIR)/xcc-cg-arm64

XTCG_68K_MAIN  = src/xtcg-68k/main.m
XTCG_68K_OBJ   = $(XTCG_68K_MAIN:.m=.o)
XTCG_68K_BIN   = $(BIN_DIR)/xcc-cg-68k

XTCG_ARM9_MAIN = src/xtcg-arm9/main.m
XTCG_ARM9_OBJ  = $(XTCG_ARM9_MAIN:.m=.o)
XTCG_ARM9_BIN  = $(BIN_DIR)/xcc-cg-arm9

XTCG_X8664_MAIN = src/xtcg-x86_64/main.m
XTCG_X8664_OBJ  = $(XTCG_X8664_MAIN:.m=.o)
XTCG_X8664_BIN  = $(BIN_DIR)/xcc-cg-x86_64

XTCG_WIN64_MAIN = src/xtcg-win64/main.m
XTCG_WIN64_OBJ  = $(XTCG_WIN64_MAIN:.m=.o)
XTCG_WIN64_BIN  = $(BIN_DIR)/xcc-cg-win64

XTCG_WASM32_MAIN = src/xtcg-wasm32/main.m
XTCG_WASM32_OBJ  = $(XTCG_WASM32_MAIN:.m=.o)
XTCG_WASM32_BIN  = $(BIN_DIR)/xcc-cg-wasm32

# ── xts (sim6502 simulator) ──────────────────────────────────────────
SIM_BIN  = $(BIN_DIR)/xcc-sim-6502

# ── xst (sim68k — Atari ST 68000/68030 simulator) ────────────────────
SIM68K_BIN = $(BIN_DIR)/xcc-sim-68k

# ── Install ──────────────────────────────────────────────────────────
# `make install` is EXPLICIT. Building used to copy support/ into /opt/xtc and
# each binary into ~/bin as a side effect, which meant a build could change the
# compiler that other work was using, and left old names behind on PATH after a
# rename. A build now writes only inside the tree.
#
#   PREFIX      install root      (default /opt/xcc/<version>)
#   BINDIR      binaries
#   LIBDIR      shared libraries
#   XCDIR       the support tree  (LIBDIR/xc)
#
# Windows puts the binaries and libraries in the install root itself and the
# support tree in <root>/xc, because there is no useful bin/lib split there.
SUPPORT_SRCS   = $(shell find support -type f)

ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  PREFIX ?= C:/Program Files/xcc
  BINDIR ?= $(PREFIX)
  LIBDIR ?= $(PREFIX)
  XCDIR  ?= $(PREFIX)/xc
else
  PREFIX ?= /opt/xcc/$(VERSION)
  BINDIR ?= $(PREFIX)/bin
  LIBDIR ?= $(PREFIX)/lib
  XCDIR  ?= $(LIBDIR)/xc
endif

# Machine-specific settings: build.env at the repository root (see
# build.env.template). A value set in the environment or on the command line wins.
BUILD_ENV := $(wildcard ../build.env)
build_env = $(if $(BUILD_ENV),$(shell sed -n 's/^$(1)=//p' $(BUILD_ENV)))

# The arm9 sysroot comes from the XTOS loader build. Vendored in when present so that
# `xcc -A arm9` needs no -L; absent, install says so rather than producing a
# toolchain that fails only when someone finally targets arm9.
ARM9_SYSROOT ?= $(call build_env,XTC_ARM9_SYSROOT)

# The x86-64 musl and win64 mingw link POOLS (task #32). The in-house static
# links resolve libc from these archives; vendoring them into the install is
# what keeps `xcc -A x86_64` / `-A win64` toolchain-free on a machine that
# never installed /opt/clang — the whole point of the in-house toolchain.
# Absent, install says so, same policy as the arm9 sysroot.
X86_64_POOL ?= /opt/clang/linux/x86_64-linux-musl/lib
WIN64_POOL  ?= /opt/clang/win64/x86_64-w64-mingw32
X86_64_POOL_FILES = libc.a libgcc.a
WIN64_POOL_FILES  = lib/libmingwex.a lib/libmsvcrt.a clang-rt/libclang_rt.builtins-x86_64.a

# The PRODUCTION compiler: selfhost/tools/xcc.xc, built by the reference. This
# is what an install ships as `xcc` — the Objective-C tree exists to bootstrap
# it, so what a developer runs must be the xc compiler, not its bootstrap.
#
# Built here rather than by hand so `make install` cannot ship a stale one.
XCC_XC_BIN = $(BIN_DIR)/xcc-xc
XCC_XC_SRC = selfhost/tools/xcc.xc
XCC_XC_INCS = -I support/generic/lib -I support/arm64/lib \
              -I selfhost/lexer -I selfhost/preproc -I selfhost/parser \
              -I selfhost/sema -I selfhost/ir -I selfhost/opt \
              -I selfhost/codegen -I selfhost/asm -I selfhost/link \
              -I selfhost/driver

# The support libraries are SOURCES of this binary too — the compiler is an xc
# program and compiles String.xc, Array.xc et al into itself. Without them here,
# a library fix silently did not reach the compiler that had the bug, and the
# rebuilt-looking binary still crashed.
$(XCC_XC_BIN): $(XTC_BIN) $(XCC_XC_SRC) $(wildcard selfhost/*/*.xc) \
               $(wildcard support/generic/lib/*.xc) $(wildcard support/arm64/lib/*.xc)
	@echo "  xc   building the production compiler with the bootstrap one"
	@$(XTC_BIN) -O2 -A arm64 -H . -o $@ $(XCC_XC_SRC) $(XCC_XC_INCS)

# The SAME production compiler, cross-built for the other two hosts. THE GOLDEN
# RULE is that we never ship the Objective-C build, so a platform
# without one of these gets no archive at all — these rules are what make Linux
# and Windows shippable rather than excluded.
#
# The include path is PER-TARGET. It used to be spelled `support/arm64/lib`
# unconditionally, which is fine while arm64 is the only host: point it at a
# different target and you pull in arm64's Stdio.xc, whose `_putc` declaration
# the x86_64 runtime deliberately does not vend (it routes stdio through libc
# instead), and the link fails with `undefined symbol '_putc'` — a message that
# reads like a compiler gap and is not one.
XCC_XC_TARGET_INCS = -I support/generic/lib -I support/$(1)/lib \
                     -I selfhost/lexer -I selfhost/preproc -I selfhost/parser \
                     -I selfhost/sema -I selfhost/ir -I selfhost/opt \
                     -I selfhost/codegen -I selfhost/asm -I selfhost/link \
                     -I selfhost/driver

XCC_XC_LINUX_BIN = bin/linux/xcc-xc
XCC_XC_WIN64_BIN = bin/win64/xcc-xc.exe
# The self-hosted SIGNER for the cross hosts. Defined here, beside the cross
# compilers, because production-linux/production-win64 below name them as
# prerequisites and a rule's prerequisites expand when the makefile is READ —
# defining these next to the osx signer (further down) would silently expand
# to nothing and ship the Objective-C signer again.
XCC_SIGN_XC_LINUX_BIN = bin/linux/xcc-sign-xc
XCC_SIGN_XC_WIN64_BIN = bin/win64/xcc-sign-xc.exe

$(XCC_XC_LINUX_BIN): $(XTC_BIN) $(XCC_XC_SRC) $(wildcard selfhost/*/*.xc) \
                     $(wildcard support/generic/lib/*.xc) $(wildcard support/x86_64/lib/*.xc)
	@echo "  xc   building the production compiler for x86_64 linux"
	@mkdir -p $(dir $@)
	@$(XTC_BIN) -O2 -A x86_64 -H . -o $@ $(XCC_XC_SRC) \
	            $(call XCC_XC_TARGET_INCS,x86_64)

$(XCC_XC_WIN64_BIN): $(XTC_BIN) $(XCC_XC_SRC) $(wildcard selfhost/*/*.xc) \
                     $(wildcard support/generic/lib/*.xc) $(wildcard support/win64/lib/*.xc)
	@echo "  xc   building the production compiler for win64"
	@mkdir -p $(dir $@)
	@$(XTC_BIN) -O2 -A win64 -H . -o $@ $(XCC_XC_SRC) \
	            $(call XCC_XC_TARGET_INCS,win64)

.PHONY: production-linux production-win64 production-all
production-linux: $(XCC_XC_LINUX_BIN) $(XCC_SIGN_XC_LINUX_BIN)
production-win64: $(XCC_XC_WIN64_BIN) $(XCC_SIGN_XC_WIN64_BIN)
production-all:   production production-linux production-win64

# The self-hosted signer beside it (iOS.md stage 1 / signing.md, bug 144):
# identity code signing in xtc, byte-identical to xcc-sign for the same
# identity. The install ships THIS one as xcc-sign.
XCC_SIGN_XC_BIN = $(BIN_DIR)/xcc-sign-xc
$(XCC_SIGN_XC_BIN): $(XTC_BIN) selfhost/tools/xtsign.xc selfhost/link/CodeSign.xc \
                    $(wildcard selfhost/link/*.xc) $(wildcard support/generic/lib/*.xc)
	@echo "  xc   building the production signer with the bootstrap compiler"
	@$(XTC_BIN) -O2 -A arm64 -H . -o $@ selfhost/tools/xtsign.xc -I selfhost/asm -I selfhost/link

# ...and for the cross hosts. The signing ENGINE is host-neutral: an Apple
# Development identity exported once on a Mac signs, on an x86-64 Linux machine
# with no Apple software, a Mach-O that macOS codesign -v validates through the
# full chain. Only --export-identity
# and --fetch-identity need host keychain/TLS, and those stay with the
# Objective-C xcc-sign, which ships beside these as xcc-sign-bootstrap.
$(XCC_SIGN_XC_LINUX_BIN): $(XTC_BIN) selfhost/tools/xtsign.xc selfhost/link/CodeSign.xc \
                    $(wildcard selfhost/link/*.xc) $(wildcard support/generic/lib/*.xc)
	@echo "  xc   building the production signer for linux"
	@$(XTC_BIN) -O2 -A x86_64 -H . -o $@ selfhost/tools/xtsign.xc -I selfhost/asm -I selfhost/link

$(XCC_SIGN_XC_WIN64_BIN): $(XTC_BIN) selfhost/tools/xtsign.xc selfhost/link/CodeSign.xc \
                    $(wildcard selfhost/link/*.xc) $(wildcard support/generic/lib/*.xc)
	@echo "  xc   building the production signer for win64"
	@$(XTC_BIN) -O2 -A win64 -H . -o $@ selfhost/tools/xtsign.xc -I selfhost/asm -I selfhost/link

.PHONY: production
production: $(XCC_XC_BIN) $(XCC_SIGN_XC_BIN)

INSTALL_BINS = $(XTC_BIN) $(XTA_BIN) $(SIM_BIN) $(SIM68K_BIN) $(XTC_FE_BIN) \
               $(XTCG_6502_BIN) $(XTCG_ARM64_BIN) $(XTCG_68K_BIN) \
               $(XTCG_ARM9_BIN) $(XTCG_X8664_BIN) $(XTCG_WIN64_BIN) \
               $(XTCG_WASM32_BIN) \
               $(XTCLN_ARM64_BIN) $(XTCLN_X8664_BIN) $(XTCLN_WIN64_BIN) \
               $(XTCLN_ARM9_BIN) $(XTCLN_WASM32_BIN) $(XTSIGN_BIN)

# The three self-hosted linkers. Their *_BIN names are defined HERE, above
# `all:`, and not next to their link rules further down: make expands a
# rule's prerequisites when it READS the rule, so a variable defined later
# expands to nothing — `all` then silently skipped these three and an
# incremental build kept handing you a stale linker.
XTCLN_ARM64_BIN = $(BIN_DIR)/xcc-ln-arm64
XTCLN_X8664_BIN = $(BIN_DIR)/xcc-ln-x86_64
XTCLN_WIN64_BIN = $(BIN_DIR)/xcc-ln-win64
XTCLN_WASM32_BIN = $(BIN_DIR)/xcc-ln-wasm32

# ── xcc-sign (developer code signer) ────────────────────────────────
# In-house DER/RSA/CMS + CodeDirectory + Mach-O re-splice. No Apple APIs,
# so it cross-builds and runs on every host (docs/mobile/signing.md).
XTSIGN_BIN = $(BIN_DIR)/xcc-sign
XTCLN_ARM9_BIN = $(BIN_DIR)/xcc-ln-arm9

all: $(XTC_BIN) $(XTA_BIN) $(SIM_BIN) $(SIM68K_BIN) $(XTC_FE_BIN) $(XTCG_6502_BIN) $(XTCG_ARM64_BIN) $(XTCG_68K_BIN) $(XTCG_ARM9_BIN) $(XTCG_X8664_BIN) $(XTCG_WIN64_BIN) $(XTCG_WASM32_BIN) $(XTCLN_ARM64_BIN) $(XTCLN_X8664_BIN) $(XTCLN_WIN64_BIN) $(XTCLN_WASM32_BIN) $(XTCLN_ARM9_BIN) $(XTSIGN_BIN)

$(BIN_DIR):
	@mkdir -p $@

# check-install — every shipped binary's rule installs it, and the binary on PATH is the one we
# built.  Runs inside `make test`; also standalone, for the moment a bug "still reproduces" and the
# first question is which compiler is actually running.  See tools/check-install.sh.
.PHONY: check-install
check-install: ; @sh tools/check-install.sh

.PHONY: install uninstall

install: all $(XCC_XC_BIN) $(XCC_SIGN_XC_BIN)
	@echo "installing -> $(PREFIX)"
	@mkdir -p "$(BINDIR)" "$(LIBDIR)" "$(XCDIR)"
	@for b in $(INSTALL_BINS); do \
		dst="$(BINDIR)/$$(basename $$b)"; \
		if ! cmp -s $$b "$$dst" 2>/dev/null; then \
			$(CP) $$b "$$dst"; echo "  bin  $$(basename $$b)"; \
			case "$$(uname)" in Darwin) codesign -f -s - "$$dst" 2>/dev/null || true;; esac; \
		fi; \
	done
	@# The Darwin codesign above is load-bearing: overwriting an installed
	@# binary IN PLACE leaves the kernel's code-signature cache stale, and the
	@# next exec dies with SIGKILL (exit 137) and no message at all. Re-signing
	@# ad-hoc after the copy resets it. Found when the freshly reinstalled
	@# /opt/xcc/0.3 xcc was killed before printing -v.
	@# Content-based, not mtime-based: a stale install that merely looks newer
	@# must not win over the tree it was built from.
	@# The shipped `xcc` is the PRODUCTION compiler — selfhost/tools/xcc.xc built
	@# by the bootstrap one. The Objective-C tree exists to bootstrap the xc
	@# compiler, so what a developer runs has to be the xc compiler.
	@#
	@# The bootstrap goes in beside it as `xcc-bootstrap`, NOT as a second
	@# thing called `xcc` in another directory: debugging the wrong compiler
	@# because two of them share a name has cost this project time twice
	@# (#1000, #1005), and a name that says what it is costs nothing.
	@$(CP) "$(BINDIR)/xcc" "$(BINDIR)/xcc-bootstrap"
	@$(CP) $(XCC_XC_BIN) "$(BINDIR)/xcc"
	@# The signer likewise: the xtc one ships as xcc-sign (identity signing,
	@# byte-identical to the Objective-C tool); the Objective-C one stays
	@# beside it as xcc-sign-bootstrap for the keychain export and the App
	@# Store Connect fetch, which are host APIs the port does not carry.
	@$(CP) "$(BINDIR)/xcc-sign" "$(BINDIR)/xcc-sign-bootstrap"
	@$(CP) $(XCC_SIGN_XC_BIN) "$(BINDIR)/xcc-sign"
	@case "$$(uname)" in Darwin) codesign -f -s - "$(BINDIR)/xcc" 2>/dev/null || true; \
	                             codesign -f -s - "$(BINDIR)/xcc-bootstrap" 2>/dev/null || true; \
	                             codesign -f -s - "$(BINDIR)/xcc-sign" 2>/dev/null || true; \
	                             codesign -f -s - "$(BINDIR)/xcc-sign-bootstrap" 2>/dev/null || true;; esac
	@echo "  bin  xcc            (production — the xc compiler)"
	@echo "  bin  xcc-bootstrap  (the Objective-C compiler that built it)"
	@echo "  bin  xcc-sign       (production — the xc signer; xcc-sign-bootstrap exports/fetches identities)"
	@n=0; for src in $(SUPPORT_SRCS); do \
		dst="$(XCDIR)/$${src#support/}"; \
		mkdir -p "$$(dirname "$$dst")"; \
		if ! cmp -s $$src "$$dst" 2>/dev/null; then $(CP) $$src "$$dst"; n=$$((n+1)); fi; \
	done; echo "  xc   $$n file(s) updated"
	@# Prune what the tree no longer has. A copy-only sync leaves a MOVED file
	@# at its old path, where it still shadows — exactly how #767's win64 stubs
	@# survived #770 and kept killing the gdi32 auto-link for every build run
	@# outside the repo.
	@#
	@# arm9-sysroot is EXEMPT: this repo is not its source (it is copied in from
	@# the XTOS loader build), so "the tree no longer has it" is never true of it.
	@#
	@# The third-party tree needs NO exemption, and must not have one: it lives
	@# at /opt/xcc/3p, a SIBLING of the versioned root, and this walk covers only
	@# <root>/lib/xc — so it is out of reach by PLACEMENT, which is the whole
	@# point of putting it there (private:docs/Design/third-party-libraries.md). A
	@# package under <root>/lib/xc/3p is in the wrong place, is never searched,
	@# and is pruned like any other stale path rather than being kept alive and
	@# looking installed.
	@if [ -d "$(XCDIR)" ]; then \
		find "$(XCDIR)" -type f | while read dst; do \
			rel=$${dst#$(XCDIR)/}; \
			case "$$rel" in arm9-sysroot/*|x86_64-sysroot/*|win64-sysroot/*) continue;; esac; \
			[ -f "support/$$rel" ] || { rm -f "$$dst"; echo "  prune $$rel"; }; \
		done; \
	fi
	@if [ -d "$(ARM9_SYSROOT)" ]; then \
		mkdir -p "$(XCDIR)/arm9-sysroot"; \
		$(CP) -R $(ARM9_SYSROOT)/. "$(XCDIR)/arm9-sysroot/" 2>/dev/null || true; \
		echo "  xc   arm9-sysroot <- $(ARM9_SYSROOT)"; \
	else \
		echo "  NOTE arm9 sysroot not found at $(ARM9_SYSROOT) —"; \
		echo "       'xcc -A arm9' will need -L until you install it"; \
	fi
	@# The link pools, flattened into <root>/lib/xc/{x86_64,win64}-sysroot.
	@# This repo is not their source either (they come from /opt/clang), so
	@# both are prune-EXEMPT above, exactly as arm9-sysroot is.
	@if [ -d "$(X86_64_POOL)" ]; then \
		mkdir -p "$(XCDIR)/x86_64-sysroot"; \
		for f in $(X86_64_POOL_FILES); do \
			src="$(X86_64_POOL)/$$f"; dst="$(XCDIR)/x86_64-sysroot/$$(basename $$f)"; \
			[ -f "$$src" ] && { cmp -s "$$src" "$$dst" 2>/dev/null || $(CP) "$$src" "$$dst"; }; \
		done; \
		echo "  xc   x86_64-sysroot <- $(X86_64_POOL)"; \
	else \
		echo "  NOTE x86-64 musl pool not found at $(X86_64_POOL) —"; \
		echo "       'xcc -A x86_64' static links will need XTC_X86_64_TOOLCHAIN"; \
	fi
	@if [ -d "$(WIN64_POOL)" ]; then \
		mkdir -p "$(XCDIR)/win64-sysroot"; \
		for f in $(WIN64_POOL_FILES); do \
			src="$(WIN64_POOL)/$$f"; dst="$(XCDIR)/win64-sysroot/$$(basename $$f)"; \
			[ -f "$$src" ] && { cmp -s "$$src" "$$dst" 2>/dev/null || $(CP) "$$src" "$$dst"; }; \
		done; \
		echo "  xc   win64-sysroot <- $(WIN64_POOL)"; \
	else \
		echo "  NOTE win64 mingw pool not found at $(WIN64_POOL) —"; \
		echo "       'xcc -A win64' links will need XTC_WIN64_TOOLCHAIN"; \
	fi
	@$(MAKE) install-tls
	@echo "done. add to PATH:  $(BINDIR)"

# The pre-0.4 install: every build copied each binary into ~/bin, under the old
# names. Those copies are still on PATH and still shadow, which is the exact
# failure check-install exists to catch — so removing them is part of migrating,
# not housekeeping. Separate target because it deletes from $$HOME.
.PHONY: uninstall-legacy
LEGACY_BINS = xtc xtc-fe xtcg-6502 xtcg-arm64 xtcg-68k xtcg-arm9 xtcg-x86_64 \
              xtcg-win64 xtcln-arm64 xtcln-x86_64 xtcln-win64 xtcln-arm9 xta xts xst \
              xcc xcc-fe xcc-as xcc-sim-6502 xcc-sim-68k \
              xcc-cg-6502 xcc-cg-arm64 xcc-cg-68k xcc-cg-arm9 xcc-cg-x86_64 \
              xcc-cg-win64 xcc-cg-wasm32 xcc-ln-arm64 xcc-ln-x86_64 xcc-ln-arm9 \
              xcc-ln-win64 xcc-ln-wasm32
uninstall-legacy:
	@n=0; for b in $(LEGACY_BINS); do \
		if [ -e "$$HOME/bin/$$b" ]; then rm -f "$$HOME/bin/$$b"; echo "  rm ~/bin/$$b"; n=$$((n+1)); fi; \
	done; \
	if [ $$n = 0 ]; then echo "  nothing to remove"; \
	else echo "removed $$n stale binary/binaries from ~/bin"; fi

uninstall:
	@echo "removing -> $(PREFIX)"
	@for b in $(INSTALL_BINS); do rm -f "$(BINDIR)/$$(basename $$b)"; done
	@# The whole support tree: everything under it came from this repo. The
	@# third-party tree is NOT under it — /opt/xcc/3p is a sibling of the
	@# versioned root, and PREFIX is that versioned root — so an uninstall
	@# cannot reach it and needs no exemption to avoid it.
	@rm -rf "$(XCDIR)"
	@rmdir "$(BINDIR)" "$(LIBDIR)" "$(PREFIX)" 2>/dev/null || true

# xtc — thin dispatcher. Parses options, then spawns xtc-fe (→ IR text) and
# xtcg-<arch> (→ asm/xex); an arm64 executable is finished by clang. It does no
# compilation in-process, so it links only its main + the shared driver-core
# (command-line options, memory model, linker-script parser).
# The APK writer is the one thing the dispatcher builds ITSELF rather than
# spawning a tool for: an APK is a container around output the pipeline has
# already finished, so there is nothing to hand to a sibling binary. It brings
# the signer, and the signer brings the crypto and DER writer it shares with
# Apple code signing.
GRP_APK        = src/xtc/link/XTApkWriter.o \
                 src/xtc/sign/XTApkSign.o \
                 src/xtc/sign/XTCrypto.o \
                 src/xtc/sign/XTDer.o

# The Mach-O -> ELF asm rewrite, used by the android link. It moved out of
# main.m so the arm64 codegen tests could share it (one implementation, no
# drift), which means the driver now has to link it explicitly — this list is
# hand-picked, not a wildcard.
GRP_ELFREWRITE = src/xtc/link/XTMachOToElfArm64.o

XTC_OBJS_TRIM = src/xtc/main.o $(GRP_DRV_CORE) $(GRP_DIAG) $(GRP_SRCLOC) $(GRP_APK) \
                $(GRP_ELFREWRITE)

$(XTC_BIN): $(XTC_OBJS_TRIM) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTC_OBJS_TRIM)

$(XTA_BIN): $(XTA_OBJS) $(XTA_MODEL_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTA_OBJS) $(XTA_MODEL_OBJS)

$(SIM_BIN): src/xts/sim6502.c | $(BIN_DIR)
	$(CC) -Wall -Wextra -O2 -std=c11 $(VERSION_DEF) -o $@ $< -lm

$(SIM68K_BIN): src/xst/sim68k.c | $(BIN_DIR)
	$(CC) -Wall -Wextra -O2 -std=c11 $(VERSION_DEF) -o $@ $< -lm

# xtc-fe — frontend only. Preprocess + lex + parse + sema + IR-lower +
# verify + IR printer. NO legacy codegen, NO target backends, NO xta.
XTC_FE_OBJS = $(XTC_FE_OBJ) \
              $(GRP_DRV_CORE) $(GRP_DRV_NEWIR) \
              $(GRP_TYPES) $(GRP_AST) $(GRP_LEXER) $(GRP_PARSER) \
              $(GRP_PREPROC) $(GRP_SEMA) $(GRP_DIAG) $(GRP_DWARF) $(GRP_SUPPORT) \
              $(GRP_IR_FULL) $(GRP_CG_SHARED)

$(XTC_FE_BIN): $(XTC_FE_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTC_FE_OBJS)

# xtcg-6502 — IR parser + opt + XT6502Backend + runtime emitter + xta.
# NO frontend (preproc/lex/parse/sema/AST), NO arm64 backend, NO legacy.
XTCG_6502_OBJS = $(XTCG_6502_OBJ) \
                 $(GRP_DRV_CORE) $(GRP_RUNTIME_EM) \
                 $(GRP_TYPES) $(GRP_DIAG) $(GRP_SUPPORT) $(GRP_SRCLOC) \
                 $(GRP_IR) $(GRP_CG_XT6502) $(GRP_CG_SHARED)

$(XTCG_6502_BIN): $(XTCG_6502_OBJS) $(XTA_LIB_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCG_6502_OBJS) $(XTA_LIB_OBJS)

# xtcg-arm64 — IR parser + opt + XTArm64Backend. No xta, no runtime
# emitter, no xt6502 backend, no frontend, no legacy.
XTCG_ARM64_OBJS = $(XTCG_ARM64_OBJ) \
                  $(GRP_DRV_CORE) \
                  $(GRP_TYPES) $(GRP_DIAG) $(GRP_SUPPORT) $(GRP_SRCLOC) \
                  $(GRP_IR) $(GRP_CG_ARM64) $(GRP_CG_SHARED)

$(XTCG_ARM64_BIN): $(XTCG_ARM64_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCG_ARM64_OBJS)

# xtcln-arm64 — the self-hosted arm64/macOS linker (assemble + Mach-O + sign).
# Spawned by the dispatcher under --self-host in place of clang. Thin: just its
# main + the in-house assembler and Mach-O writer.
XTCLN_ARM64_OBJS = src/xtcln-arm64/main.o src/xtc/asm/arm64/XAArm64Assembler.o \
                   src/xtc/link/XTMachOWriter.o src/xtc/link/XTElfArm64Writer.o
$(XTCLN_ARM64_BIN): $(XTCLN_ARM64_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCLN_ARM64_OBJS)

# xtcln-x86_64 — the self-hosted x86-64/Linux linker (assemble + ELF). Lets a
# Mac produce a Linux binary with no Linux toolchain involved.
XTCLN_X8664_OBJS = src/xtcln-x86_64/main.o src/xtc/asm/x86_64/XAX86_64Assembler.o \
                   src/xtc/link/XTElfWriter.o src/xtc/link/XTElfGC.o src/xtc/link/XTArArchive.o
$(XTCLN_X8664_BIN): $(XTCLN_X8664_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCLN_X8664_OBJS)

# xtcln-arm9 — the in-house ARM32 assembler + ELF32 object writer. `-c` for
# arm9 goes through here on EVERY host: arm-none-eabi-gcc is not on the device
# and not on Windows, and a compiler that needs someone else's toolchain to
# produce an object is not portable, it is merely hosted.
XTCLN_ARM9_OBJS = src/xtcln-arm9/main.o src/xtc/asm/arm32/XAArm32Assembler.o \
                  src/xtc/link/XTElf32Writer.o src/xtc/link/XTArArchive.o
$(XTCLN_ARM9_BIN): $(XTCLN_ARM9_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCLN_ARM9_OBJS)

# xtcln-win64 — the self-hosted x86-64/Windows linker (assemble + PE/COFF). The
# assembler is shared verbatim with the Linux target; only the container differs.
XTCLN_WIN64_OBJS = src/xtcln-win64/main.o src/xtc/asm/x86_64/XAX86_64Assembler.o \
                   src/xtc/link/XTPEWriter.o src/xtc/link/XTArArchive.o
$(XTCLN_WIN64_BIN): $(XTCLN_WIN64_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCLN_WIN64_OBJS)

# xtcg-68k — IR parser + opt + XTM68kBackend (Atari ST/TT). Same shape
# as xtcg-arm64; no xta/runtime emitter yet (xta68 lands in M2.1).
XTCG_68K_OBJS = $(XTCG_68K_OBJ) \
                $(GRP_DRV_CORE) \
                $(GRP_TYPES) $(GRP_DIAG) $(GRP_SUPPORT) $(GRP_SRCLOC) \
                $(GRP_IR) $(GRP_CG_M68K) $(GRP_CG_SHARED)

$(XTCG_68K_BIN): $(XTCG_68K_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCG_68K_OBJS)

# xtcg-arm9 — IR parser + opt + XTArm9Backend (ARMv7-A / AArch32, Zynq
# Cortex-A9). Same shape as xtcg-arm64; assembled+linked by arm-none-eabi.
XTCG_ARM9_OBJS = $(XTCG_ARM9_OBJ) \
                 $(GRP_DRV_CORE) \
                 $(GRP_TYPES) $(GRP_DIAG) $(GRP_SUPPORT) $(GRP_SRCLOC) \
                 $(GRP_IR) $(GRP_CG_ARM9) $(GRP_CG_SHARED)

$(XTCG_ARM9_BIN): $(XTCG_ARM9_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCG_ARM9_OBJS)

# xtcg-x86_64 — IR parser + opt + XTX86_64Backend (System V AMD64, Linux/musl).
# Same shape as the other xtcg-*; assembled+linked by the musl cross-clang.
XTCG_X8664_OBJS = $(XTCG_X8664_OBJ) \
                  $(GRP_DRV_CORE) \
                  $(GRP_TYPES) $(GRP_DIAG) $(GRP_SUPPORT) $(GRP_SRCLOC) \
                  $(GRP_IR) $(GRP_CG_X8664) $(GRP_CG_SHARED)

$(XTCG_X8664_BIN): $(XTCG_X8664_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCG_X8664_OBJS)

# xtcg-win64 — IR parser + opt + XTX86_64Backend in Win64-ABI mode. SAME codegen
# object group as xtcg-x86_64 (one backend, two ABIs); assembled+linked into a
# static PE by the mingw-w64 cross-clang.
XTCG_WIN64_OBJS = $(XTCG_WIN64_OBJ) \
                  $(GRP_DRV_CORE) \
                  $(GRP_TYPES) $(GRP_DIAG) $(GRP_SUPPORT) $(GRP_SRCLOC) \
                  $(GRP_IR) $(GRP_CG_X8664) $(GRP_CG_SHARED)

$(XTCG_WIN64_BIN): $(XTCG_WIN64_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCG_WIN64_OBJS)

# xtcg-wasm32 — IR parser + opt + XTWasmBackend (WebAssembly). Same shape as
# its siblings; the WAT it emits is assembled to .wasm by xcc-ln-wasm32.
XTCG_WASM32_OBJS = $(XTCG_WASM32_OBJ) \
                   $(GRP_DRV_CORE) \
                   $(GRP_TYPES) $(GRP_DIAG) $(GRP_SUPPORT) $(GRP_SRCLOC) \
                   $(GRP_IR) $(GRP_CG_WASM32) $(GRP_CG_SHARED)

$(XTCG_WASM32_BIN): $(XTCG_WASM32_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCG_WASM32_OBJS)

# xcc-ln-wasm32 — the in-house wasm module builder: assembles the WAT that
# xcc-cg-wasm32 emits into a .wasm binary (XTWasmWriter — LEB128 sections, no
# relocations, no external wat2wasm) and writes the JS loader beside it.
XTCLN_WASM32_OBJS = src/xtcln-wasm32/main.o src/xtc/link/XTWasmWriter.o
$(XTCLN_WASM32_BIN): $(XTCLN_WASM32_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTCLN_WASM32_OBJS)

# ── Optional TLS (Route 1: online App Store Connect signing) ──────────
# The `tls` 3p source lives OUTSIDE the compiler subtree, at
# ../frameworks/3p/tls (the xc monorepo layout). The compiler VENDORS it as a
# build input for its own tool xcc-sign, and separately INSTALLS it to
# /opt/xcc/3p for xtc programs (`make install-tls`, folded into `make install`).
# tlsshim.o is built into build/ (never into the pristine framework source).
# If the source or Mbed TLS is absent, xcc-sign still builds — signing + Route 2
# only — and --fetch-identity reports it was built without TLS.
TLS_SRC        ?= ../frameworks/3p/tls
MBEDTLS_PREFIX ?= /opt/homebrew/opt/mbedtls
ifneq ($(wildcard $(TLS_SRC)/tlsshim.c),)
ifneq ($(wildcard $(MBEDTLS_PREFIX)/include/mbedtls/ssl.h),)
  TLS_CFLAGS := -DXT_HAVE_TLS=1 -I$(MBEDTLS_PREFIX)/include -I$(TLS_SRC) -Isrc/xtc/net
  TLS_LIBS   := -L$(MBEDTLS_PREFIX)/lib -lmbedtls -lmbedx509 -lmbedcrypto -ltfpsacrypto
  CFLAGS += $(TLS_CFLAGS)
  XTSIGN_TLS_OBJS := src/xtc/net/XTHttps.o src/xtc/sign/XTAscApi.o build/tls/tlsshim.o
endif
endif

# xcc-sign — the developer code signer. Its own main + the signing engine
# (DER, crypto, CMS, CodeDirectory + Mach-O re-splice). Thin: no compiler deps.
XTSIGN_BASE_OBJS = src/xtc-sign/main.o \
              src/xtc/sign/XTDer.o src/xtc/sign/XTDerReader.o \
              src/xtc/sign/XTCrypto.o src/xtc/sign/XTCms.o \
              src/xtc/sign/XTCodeSign.o src/xtc/sign/XTCodeResources.o \
              src/xtc/sign/XTIdentity.o \
              src/xtc/sign/XTPkcs8.o src/xtc/sign/XTIdentityExport.o
XTSIGN_OBJS = $(XTSIGN_BASE_OBJS) $(XTSIGN_TLS_OBJS)
$(XTSIGN_BIN): $(XTSIGN_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(XTSIGN_OBJS) $(TLS_LIBS)

# tlsshim.c is C (not ObjC): its own rule, no -fobjc-arc. Built into build/
# (the framework source at $(TLS_SRC) stays pristine — the compiler only reads it).
build/tls/tlsshim.o: $(TLS_SRC)/tlsshim.c | build/tls
	$(CC) -O2 $(TLS_CFLAGS) -c -o $@ $<
build/tls:
	@mkdir -p $@

# install-tls — the compiler INSTALLS the tls 3p lib to /opt/xcc/3p (decision A):
# the host-linkable shim (for xcc-sign and other host tools) plus the xtc
# libtls (for `#use <tls>` in xtc programs, built by install.sh via xcc).
# Folded into `make install`; also runnable standalone. Needs xcc built first
# for the xtc-lib half.
.PHONY: install-tls
install-tls: $(XTC_BIN) $(XTC_FE_BIN) $(XTCG_ARM64_BIN) $(XTCLN_ARM64_BIN)
	@if [ ! -f "$(TLS_SRC)/tlsshim.c" ]; then \
	  echo "install-tls: no tls source at $(TLS_SRC) — skipped"; exit 0; fi
	@mkdir -p /opt/xcc/3p/tls/host
	$(CC) -O2 -I$(MBEDTLS_PREFIX)/include -I$(TLS_SRC) -c $(TLS_SRC)/tlsshim.c -o /opt/xcc/3p/tls/host/tlsshim.o
	$(CP) $(TLS_SRC)/tlsshim.h /opt/xcc/3p/tls/host/
	@echo "  3p   tls host shim -> /opt/xcc/3p/tls/host"
	@# install.sh runs from $(TLS_SRC), whose cwd holds an `xc/` subdir — the
	@# xtc SOURCE, not a support tree. An in-tree xcc, having no support beside
	@# its own binary, would fall through to the cwd probe, match `./xc`, and
	@# then miss arm64/runtime → a silent clang fallback that fails. Use the
	@# INSTALLED xcc (support resolves via its own location) and pin XCC_HOME so
	@# the ambiguous cwd never enters resolution. Standalone (pre-install), fall
	@# back to the in-tree binary with the in-tree tree as home.
	@# …and the BOOTSTRAP one specifically. Building an xtc library needs
	@# `--emit-lib`, which the xc driver has not ported yet, so the shipped
	@# `xcc` answers "unrecognised option" here. Naming xcc-bootstrap says that
	@# out loud instead of leaving the install printing an error, and it is the
	@# only step in the install that still needs the bootstrap compiler.
	@# Remove this the day --emit-lib lands in the xc driver.
	@if [ -x "$(BINDIR)/xcc-bootstrap" ]; then TLSXCC="$(BINDIR)/xcc-bootstrap"; TLSHOME="$(PREFIX)"; \
	 elif [ -x "$(BINDIR)/xcc" ]; then TLSXCC="$(BINDIR)/xcc"; TLSHOME="$(PREFIX)"; \
	 else TLSXCC="$(abspath $(XTC_BIN))"; TLSHOME="$(CURDIR)"; fi; \
	 XCC="$$TLSXCC" XCC_HOME="$$TLSHOME" sh $(TLS_SRC)/install.sh || \
	  echo "  NOTE tls xtc-lib install reported an issue (host shim installed)"

%.o: %.m
	$(CC) $(CFLAGS) -c -o $@ $<

# Include any depfiles that have been generated so far. On the first
# build the wildcard expands to nothing and make proceeds with no
# header deps (which is fine — it'll build everything). After the
# first build, every .o has a .d next to it listing its header deps
# for subsequent incremental builds to consult.
-include $(XTC_OBJS:.o=.d) $(XTA_OBJS:.o=.d) $(XTA_LIB_OBJS:.o=.d)

# ── Tests ─────────────────────────────────────────────────────────────
# Standalone smoke tests (each has its own main() and is built separately).
# The old test_ir_lowering / test_xt6502 smoke tests targeted the old IR
# and codegen and were not copied. New-IR smoke
# tests are added as tasks #8-#15 land.
# The corpus sweep harness (tests/corpus/XTCorpusSweep.m) has its own
# main() and must be excluded from the unit-test bundle. It builds via
# the `make corpus` target below, which is intentionally NOT wired into
# `make test` — corpus runs are the explicit pre-commit verification
# step per the workflow memory.
STANDALONE_TESTS  = tests/corpus/XTCorpusSweep.m \
                    tests/asm-arm64/oracle-diff/harness.m \
                    tests/asm-arm64/oracle-diff/macho-smoke.m \
                    tests/asm-x86_64/oracle-diff/harness.m \
                    tests/link-elfobj/oracle-diff/harness.m \
                    tests/asm-x86_64/elf-smoke.m
STANDALONE_BINS   =
CORPUS_BIN        = $(BIN_DIR)/xtc_corpus_sweep

# Full-corpus byte-parity harness for the self-hosted AArch64 assembler
# (Phase 1, private:docs/Design/native-toolchain.md): assembles a list of instructions
# with clang and byte-diffs against XAArm64Assembler. Not wired into `make test`
# (needs clang + otool at runtime); run `make oracle-arm64` explicitly.
ORACLE_ARM64_BIN  = $(BIN_DIR)/oracle-arm64

# Unit-test runner — links all test classes together via XTTestRunner's main().
# tests/interop/ holds self-contained interop fixtures (shim .m/.c sources + .xc,
# each with its own run.sh — e.g. the AppKit objcshim.m needs -framework Cocoa);
# they are NOT unit-test classes and must not be swept into the bundle.
# Every oracle harness has its own main(), so it can never join the unit-test
# binary — excluded by PATH as well as by name, because forgetting the name
# does not fail at `make test` with a clear message, it fails with `duplicate
# symbol '_main'` in a 200-object link line.
TEST_SRCS = $(filter-out $(STANDALONE_TESTS), \
                $(shell find tests -name '*.m' -not -path 'tests/interop/*' \
                                                -not -path '*/oracle-diff/*')) \
            $(filter-out src/xtc/main.m, $(XTC_SRCS)) $(XTA_LIB_SRCS)
TEST_OBJS = $(TEST_SRCS:.m=.o)
TEST_BIN  = $(BIN_DIR)/xtc_tests

# The XT6502 / arm64 codegen suites shell out to the freshly-built xta and
# xts binaries, so make them prerequisites — otherwise `make test` silently
# runs against a stale assembler/simulator (e.g. a stale xts missed the
# PSH/PLL guard-byte ABI change, failing 18 codegen tests against good code).
test: $(TEST_BIN) $(STANDALONE_BINS) $(XTA_BIN) $(SIM_BIN)
	@printf "\n=== Checking the install step ===\n"
	@sh tools/check-install.sh
	@printf "\n=== Checking the duplicated wasm loader ===\n"
	@bash tools/check-wasm-loader.sh
	@printf "\n=== Running unit-test suite ===\n"
	./$(TEST_BIN)
	@printf "\n=== Running standalone smoke tests ===\n"
	for t in $(STANDALONE_BINS); do echo "--- $$t ---"; ./$$t; echo; done

$(TEST_BIN): $(TEST_OBJS) | $(BIN_DIR)
	$(CC) $(LDFLAGS) -o $@ $(TEST_OBJS)

# AArch64 assembler oracle-diff tool (standalone; needs clang + otool at runtime).
oracle-arm64: $(ORACLE_ARM64_BIN)
$(ORACLE_ARM64_BIN): tests/asm-arm64/oracle-diff/harness.m src/xtc/asm/arm64/XAArm64Assembler.o | $(BIN_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< src/xtc/asm/arm64/XAArm64Assembler.o

# End-to-end Mach-O smoke driver (assemble .s -> emit executable); the
# tests/asm-arm64/macho-run.sh script signs + runs its output on macOS/arm64.
macho-smoke: $(BIN_DIR)/macho-smoke
$(BIN_DIR)/macho-smoke: tests/asm-arm64/oracle-diff/macho-smoke.m \
                        src/xtc/asm/arm64/XAArm64Assembler.o src/xtc/link/XTMachOWriter.o | $(BIN_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< src/xtc/asm/arm64/XAArm64Assembler.o src/xtc/link/XTMachOWriter.o

# Build each standalone smoke test as its own binary.
# Exclude src/xtc/main.o (has its own main()) and src/xta/main.o.
XTC_OBJS_NO_MAIN = $(filter-out src/xtc/main.o src/xta/main.o, $(XTC_OBJS))

$(BIN_DIR)/test_ir_lowering: tests/test_ir_lowering.m $(XTC_OBJS_NO_MAIN) $(XTA_LIB_OBJS) | $(BIN_DIR)
	$(CC) $(OBJCFLAGS) $(DEPFLAGS) $(XTC_INCLUDES) $(XTA_INCLUDES) $(LDFLAGS) -o $@ $< $(XTC_OBJS_NO_MAIN) $(XTA_LIB_OBJS)

$(BIN_DIR)/test_xt6502: tests/test_xt6502.m $(XTC_OBJS_NO_MAIN) $(XTA_LIB_OBJS) | $(BIN_DIR)
	$(CC) $(OBJCFLAGS) $(DEPFLAGS) $(XTC_INCLUDES) $(XTA_INCLUDES) $(LDFLAGS) -o $@ $< $(XTC_OBJS_NO_MAIN) $(XTA_LIB_OBJS)

# ── Corpus sweep ──────────────────────────────────────────────────────
# Walks every fixture in tests/fixtures/, drives the full new-IR
# pipeline through the arm64 backend, classifies the outcome, and
# writes doc/new-ir-progress.md. NOT part of `make test` — this is
# the pre-commit baseline step (~5 minutes for ~300 fixtures).
#
# Set XTC_CORPUS_FILTER=<substr> to restrict the sweep to fixtures
# whose name contains the substring (smoke-test cycle). When the
# filter is active the run does not overwrite doc/new-ir-progress.md.
.PHONY: corpus
# The x86-64 backend targets System V / musl Linux: this box can build it but
# not run it, so its fixtures execute over ssh on a Linux host. Probe once here
# and WARN LOUDLY when it's down — a sweep that quietly omitted x86-64 would
# report a pass rate that doesn't cover it, which is worse than not running it.
# (The sweep binary re-checks and marks every x86 result NOT RUN, so an
# unreachable host can never be laundered into a pass.)
# Default per HOST, not globally. On macOS the x86-64 fixtures genuinely cannot
# run here, so they go to a Linux box over ssh. On an x86-64 Linux host — the CI
# box — they are native, and `localhost` tells the sweep to just run them:
# no ssh, no scp, and no coverage lost because a second machine happened to be
# down. Override either way with XTC_X86_HOST=<host>.
ifeq ($(UNAME_S),Darwin)
  XTC_X86_HOST ?= $(or $(call build_env,XTC_X86_HOST),$(call build_env,XTC_LINUX_HOST))
else ifeq ($(shell uname -m),x86_64)
  XTC_X86_HOST ?= localhost
else
  XTC_X86_HOST ?= $(or $(call build_env,XTC_X86_HOST),$(call build_env,XTC_LINUX_HOST))
endif
# Separate-compilation suite (-c objects, archives, categories across objects)
# on every host target this Mac can drive: bug 135 was eight failures nobody
# ran, so it has a name now.
# The shipped compiler's ios-sim binaries run on a booted iPhone simulator
# (bug 119's simctl sweep). Skips loudly without Xcode or a booted device.
ios-run: production
	bash selfhost/tools/ios-run.sh

objlink: all
	bash tests/objlink/run.sh

corpus: $(CORPUS_BIN) $(XTC_BIN) $(XTA_BIN) $(SIM_BIN)
	@if [ "$(XTC_X86_HOST)" = localhost ]; then \
	  echo "x86-64 fixtures run LOCALLY on this host — no ssh needed."; \
	elif ssh -o BatchMode=yes -o ConnectTimeout=5 $(XTC_X86_HOST) true 2>/dev/null; then \
	  echo "x86_64 host '$(XTC_X86_HOST)' reachable — x86-64 fixtures will run."; \
	else \
	  echo ""; \
	  echo "!! ============================================================"; \
	  echo "!!  WARNING: x86_64 host '$(XTC_X86_HOST)' is UNREACHABLE."; \
	  echo "!!  The x86-64 backend will NOT be covered by this sweep."; \
	  echo "!!  Its fixtures are scored NOT RUN — never as passing."; \
	  echo "!!  Set XTC_X86_HOST=<host> or bring '$(XTC_X86_HOST)' up."; \
	  echo "!! ============================================================"; \
	  echo ""; \
	fi
	@set -e; \
	rm -f $(CORPUS_XC_LOG); \
	( TARGET=arm64  JOBS=$(CORPUS_XC_JOBS) bash tests/corpus/xc-sweep.sh > $(CORPUS_XC_LOG) 2>&1; \
	  echo $$? > $(CORPUS_XC_LOG).rc ) & \
	xcpid=$$!; \
	( TARGET=xt6502 JOBS=$(CORPUS_XC_JOBS) bash tests/corpus/xc-sweep.sh > $(CORPUS_XC_LOG).65 2>&1; \
	  echo $$? > $(CORPUS_XC_LOG).65.rc ) & \
	xc65pid=$$!; \
	rm -f $(CORPUS_LEG_LOG).*; \
	i=0; while [ $$i -lt $(CORPUS_SHARDS) ]; do \
	  ( XTC_CORPUS_SHARD_I=$$i XTC_CORPUS_SHARD_N=$(CORPUS_SHARDS) \
	    CORPUS_TAG="$${CORPUS_TAG:-phase-015}" XTC_X86_HOST="$(XTC_X86_HOST)" \
	    ./$(CORPUS_BIN) > $(CORPUS_LEG_LOG).$$i 2>&1; \
	    echo $$? > $(CORPUS_LEG_LOG).$$i.rc ) & \
	  i=$$((i+1)); \
	done; \
	wait; \
	legacy=0; reported=0; \
	i=0; while [ $$i -lt $(CORPUS_SHARDS) ]; do \
	  grep -q '=== corpus sweep:' $(CORPUS_LEG_LOG).$$i 2>/dev/null && reported=$$((reported+1)); \
	  [ "$$(cat $(CORPUS_LEG_LOG).$$i.rc 2>/dev/null || echo 1)" = 0 ] || legacy=1; \
	  i=$$((i+1)); \
	done; \
	awk -F'[:/ ]+' '/=== corpus sweep:/{p+=$$4; t+=$$5; sk+=$$8} \
	                /^x86_64: /{xp+=$$2; xt+=$$3} \
	                END{printf "=== corpus sweep: %d / %d pass, %d skipped ===\n", p, t, sk; \
	                    if (xt) printf "x86_64: %d / %d pass\n", xp, xt}' \
	    $(CORPUS_LEG_LOG).* 2>/dev/null; \
	if [ $$reported -ne $(CORPUS_SHARDS) ]; then \
	  echo "!! only $$reported/$(CORPUS_SHARDS) legacy shards reported — treating as FAILURE"; \
	  legacy=1; \
	fi; \
	grep -h -A3 'differ\|FAIL' $(CORPUS_LEG_LOG).* 2>/dev/null | head -20 || true; \
	wait $$xcpid || true; wait $$xc65pid || true; \
	echo ""; \
	echo "── the xc compiler (what ships) ──────────────────────────────"; \
	sed 's/^/  /' $(CORPUS_XC_LOG); \
	sed 's/^/  /' $(CORPUS_XC_LOG).65; \
	xc=$$(cat $(CORPUS_XC_LOG).rc 2>/dev/null || echo 1); \
	xc65=$$(cat $(CORPUS_XC_LOG).65.rc 2>/dev/null || echo 1); \
	rm -f $(CORPUS_XC_LOG).rc $(CORPUS_XC_LOG).65.rc; \
	test $$legacy -eq 0 -a $$xc -eq 0 -a $$xc65 -eq 0

# The corpus, twice: once through the ObjC BOOTSTRAP compiler (in-process, both
# live backends) and once through the xc compiler we actually ship. They share
# nothing but the fixtures and the oracles — the xc sweep takes its own mktemp
# work dir — so they run CONCURRENTLY and the second costs almost no wall clock.
#
# Sweeping only the bootstrap is what let bug 072 sit behind a 100% green
# corpus: `.length` answering from another function's local, in the shipping
# compiler, on a fixture the legacy sweep passed every time because the legacy
# sweep runs the compiler that does not have the bug.
#
# THREE sweeps now: the bootstrap over both its backends, and the xc compiler
# over arm64 and xt6502 — the two targets it can both build and RUN (arm64
# natively, xt6502 on xcc-sim-6502). All three must pass; a red xc sweep is a
# red corpus.
CORPUS_XC_LOG := $(BIN_DIR)/corpus-xc.log
CORPUS_LEG_LOG := $(BIN_DIR)/corpus-legacy.log
# The legacy sweep is a SERIAL loop and most of its time is spent RUNNING
# fixtures (the 6502 simulator, native binaries, the ssh hop to the x86 host),
# so it splits cleanly by fixture and was the whole reason `make corpus` took
# half an hour. Each shard gets its own build root — libxt.a is built into it
# once, and shards would otherwise race for it. A shard that fails to report a
# summary makes the whole target fail rather than being quietly summed around.
# Parallelism, derived from THIS host rather than inherited from the machine it
# was first measured on — private:docs/Design/ci.md asks for exactly that ("re-derive
# shards_for on the box"). 6 shards and JOBS=4 were sized for the dev Mac; on
# the 32-thread CI box that left load at 8 with 24 cores idle.
#
# The corpus runs two xc-sweeps (JOBS each) alongside CORPUS_SHARDS in-process
# shards, so the total is 2*JOBS + SHARDS. Budget roughly one per hardware
# thread and leave a little headroom.
# The ratios are chosen so a 16-thread machine reproduces TODAY'S numbers
# exactly — JOBS=4, SHARDS=6, total 14 — because that is the dev Mac, and a
# corpus run should not quietly get heavier on the machine someone is working
# on. A 32-thread box doubles to JOBS=8, SHARDS=12, total 28.
NCPU := $(shell (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null) || echo 4)
CORPUS_XC_JOBS ?= $(shell n=$$(( $(NCPU) / 4 ));     [ $$n -lt 4 ] && n=4; echo $$n)
CORPUS_SHARDS  ?= $(shell n=$$(( $(NCPU) * 3 / 8 )); [ $$n -lt 6 ] && n=6; echo $$n)

$(CORPUS_BIN): tests/corpus/XTCorpusSweep.m $(XTC_OBJS_NO_MAIN) $(XTA_LIB_OBJS) | $(BIN_DIR)
	$(CC) $(OBJCFLAGS) $(DEPFLAGS) $(XTC_INCLUDES) $(XTA_INCLUDES) $(LDFLAGS) -o $@ $< $(XTC_OBJS_NO_MAIN) $(XTA_LIB_OBJS)

# ── Cross-arch performance harness ───────────────────────────────────
# Compiles tests/perf/kernels/*.xc through every backend and records a
# per-backend metric (dynamic instruction count for the simulated m68k /
# xt6502 targets, static instruction count for the native / emulated ones)
# plus a cross-backend checksum. Compares against tests/perf/baseline.json.
# Pass extra args via PERF_ARGS, e.g. `make perf PERF_ARGS=--update`.
.PHONY: perf
perf: all
	python3 tests/perf/run_perf.py $(PERF_ARGS)

# The external-toolchain cross-builds (Linux via /opt/clang musl, Windows via
# mingw) and the distribution archives that bundle their output are a macOS-only
# convenience: they reuse bin/linux / bin/win64 as OUTPUT dirs, which collide
# with the NATIVE build's BIN_DIR on those hosts, and they hard-code Mac
# toolchain paths. Guard them to Darwin so a native Linux (GNUstep) build sees
# only its own recipes. On Linux/Windows the self-hosted writers produce every
# target from the native binary, so these cross recipes are not needed there.
ifeq ($(UNAME_S),Darwin)

# ── Linux cross-build ────────────────────────────────────────────────
# Builds static-PIE xtc/xta/xts binaries for x86_64-linux-musl using
# the toolchain under /opt/clang/linux/. All object files land under
# build/linux/ (mirroring the source tree) so they don't clash with
# the host Darwin build, and the finished binaries plus their runtime
# and lib resources land under bin/linux/.
#
# Invoke as `make linux`. Requires the cross toolchain and its sysroot
# to be installed. The recipe is intentionally split across several
# variables so the flag sets can be audited without hunting through
# a 500-character command line.
LINUX_TOOLCHAIN  = /opt/clang/linux
LINUX_SYSROOT    = $(LINUX_TOOLCHAIN)/x86_64-linux-musl
# The wrapper at $(LINUX_TOOLCHAIN)/bin/x86_64-linux-musl-clang
# hard-codes `--config=.../x86_64-linux-musl.cfg`, and that cfg
# unconditionally adds `-stdlib=libc++` plus a libc++/libc++abi/
# libunwind linker group — which conflicts with libobjc and
# libgnustep-base, both of which were built against libstdc++.
# --no-default-config does NOT override an explicit --config, so we
# call the underlying clang directly and reconstruct the cfg's
# useful bits (target, sysroot, linker path, rtlib, unwindlib)
# ourselves, minus the libc++ pieces.
LINUX_CC         = /opt/homebrew/opt/llvm/bin/clang

LINUX_BASE_FLAGS = --target=x86_64-linux-musl \
                   --sysroot=$(LINUX_SYSROOT) \
                   -fuse-ld=lld \
                   --ld-path=/opt/homebrew/opt/lld/bin/ld.lld \
                   -rtlib=compiler-rt \
                   -unwindlib=libunwind \
                   -stdlib=libstdc++

# Objective-C compile flags for GNUstep's libs-base / libobjc2 stack.
# `-fobjc-runtime=gnustep-2.2` matches the runtime the sysroot was
# built against; `-fblocks -fobjc-arc` follows the macOS build.
# Foundation headers live under Local/Library/Headers inside the
# sysroot; the sysroot's own dispatch/ headers provide the real GCD
# typedefs so the legacy dispatch_compat shim is NOT included here
# (it would redefine dispatch_once_t with an incompatible type).
LINUX_OBJCFLAGS  = -fobjc-runtime=gnustep-2.2 -fblocks -fobjc-arc \
                   -I $(LINUX_SYSROOT)/Local/Library/Headers

LINUX_CFLAGS     = $(LINUX_BASE_FLAGS) $(LINUX_OBJCFLAGS) \
                   -Wall -Wextra -Wshadow -std=gnu11 \
                   -Wno-unused-parameter -Wno-objc-designated-initializers \
                   $(VERSION_DEF) $(DEPFLAGS) $(XTC_INCLUDES) $(XTA_INCLUDES)

# Static-PIE link. The --whole-archive pair is mandatory: GNUstep
# class-load trampolines live in archive members that the linker
# would otherwise drop, leaving `-[NSObject class]` unresolved at
# +load time. The start-group/end-group pair handles the usual
# cyclic dependency between libicu, libstdc++ and friends.
#
# -lcxxabi_compat is a minimal shim archive shipped in the sysroot
# that provides std::bad_array_new_length::bad_array_new_length()
# (the C1/C2 ctors). libobjc was compiled against libc++abi headers
# and references that ctor as an external symbol, but libstdc++
# only exports the dtor (the ctor is inlined in libstdc++ headers).
# The shim is the bad_array_new ctors carved out of libc++abi.a
# with everything else localised to avoid colliding with libstdc++.
LINUX_LDFLAGS    = $(LINUX_BASE_FLAGS) -static-pie \
                   -Wl,--whole-archive -lgnustep-base -lobjc -Wl,--no-whole-archive \
                   -Wl,--start-group \
                     -ldispatch -lBlocksRuntime \
                     -lxml2 -licuuc -licui18n -licudata -lffi -lz -llzma \
                     -lstdc++ -lsupc++ -lgcc -lgcc_eh -lcxxabi_compat \
                   -Wl,--end-group \
                   -lpthread -lm -ldl -lresolv -lrt

LINUX_BUILD_DIR  = build/linux
LINUX_BIN_DIR    = bin/linux

# Map a host object list into the cross build tree: the host build compiles
# %.m to %.o in place, the cross builds mirror the source tree under
# build/<plat>/ so the two never collide.
LINUXIZE = $(addprefix $(LINUX_BUILD_DIR)/,$(1))

# One template stamps out a cross-linked twin of a host binary from the SAME
# object-set variable its host link rule uses — the cross build can therefore
# never quietly build a different compiler than `make all` does (the pre-0.4
# cross targets did exactly that: they still built the retired three-binary
# monolith long after the host build had split into the xcc-* family).
#   $(1) binary basename, $(2) host object list.
define LINUX_BIN_template
LINUX_BINS += $(LINUX_BIN_DIR)/$(1)
LINUX_OBJS += $(call LINUXIZE,$(2))
$(LINUX_BIN_DIR)/$(1): $(call LINUXIZE,$(2)) | $(LINUX_BIN_DIR)
	$$(LINUX_CC) $$(LINUX_LDFLAGS) -o $$@ $(call LINUXIZE,$(2))
endef

$(eval $(call LINUX_BIN_template,xcc,$(XTC_OBJS_TRIM)))
$(eval $(call LINUX_BIN_template,xcc-as,$(XTA_OBJS) $(XTA_MODEL_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-fe,$(XTC_FE_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-cg-6502,$(XTCG_6502_OBJS) $(XTA_LIB_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-cg-arm64,$(XTCG_ARM64_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-cg-68k,$(XTCG_68K_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-cg-arm9,$(XTCG_ARM9_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-cg-x86_64,$(XTCG_X8664_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-cg-win64,$(XTCG_WIN64_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-cg-wasm32,$(XTCG_WASM32_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-ln-arm64,$(XTCLN_ARM64_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-ln-x86_64,$(XTCLN_X8664_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-ln-arm9,$(XTCLN_ARM9_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-ln-win64,$(XTCLN_WIN64_OBJS)))
$(eval $(call LINUX_BIN_template,xcc-ln-wasm32,$(XTCLN_WASM32_OBJS)))

# xcc-sign for Linux. If the vendored musl Mbed TLS is present it gets Route 1
# (online App Store Connect) too; otherwise it's the signer + Route 2 only.
LINUX_MBEDTLS := $(TLS_SRC)/mbedtls-linux
ifneq ($(wildcard $(LINUX_MBEDTLS)/libmbedtls.a),)
  LINUX_TLS_CFLAGS := -DXT_HAVE_TLS=1 -I$(MBEDTLS_PREFIX)/include -I$(TLS_SRC) -Isrc/xtc/net
  LINUX_TLS_OBJS := $(LINUX_BUILD_DIR)/src/xtc/net/XTHttps.o \
                    $(LINUX_BUILD_DIR)/src/xtc/sign/XTAscApi.o \
                    $(LINUX_BUILD_DIR)/tls/tlsshim.o
  # These three .m objects (+ main) need the TLS cflags on top of LINUX_CFLAGS.
  $(LINUX_BUILD_DIR)/src/xtc/net/XTHttps.o \
  $(LINUX_BUILD_DIR)/src/xtc/sign/XTAscApi.o \
  $(LINUX_BUILD_DIR)/src/xtc-sign/main.o: LINUX_EXTRA_CFLAGS := $(LINUX_TLS_CFLAGS)
  $(LINUX_BUILD_DIR)/tls/tlsshim.o: $(TLS_SRC)/tlsshim.c
	@mkdir -p $(dir $@)
	$(LINUX_CC) --target=x86_64-linux-musl --sysroot=$(LINUX_SYSROOT) -O2 $(LINUX_TLS_CFLAGS) -c -o $@ $<
  LINUX_SIGN_LIBS := -L $(LINUX_MBEDTLS) -lmbedtls -lmbedx509 -lmbedcrypto -ltfpsacrypto
else
  LINUX_TLS_OBJS :=
  LINUX_SIGN_LIBS :=
endif
LINUX_BINS += $(LINUX_BIN_DIR)/xcc-sign
LINUX_OBJS += $(call LINUXIZE,$(XTSIGN_BASE_OBJS)) $(LINUX_TLS_OBJS)
$(LINUX_BIN_DIR)/xcc-sign: $(call LINUXIZE,$(XTSIGN_BASE_OBJS)) $(LINUX_TLS_OBJS) | $(LINUX_BIN_DIR)
	$(LINUX_CC) $(LINUX_LDFLAGS) -o $@ $(call LINUXIZE,$(XTSIGN_BASE_OBJS)) $(LINUX_TLS_OBJS) $(LINUX_SIGN_LIBS)

# The simulators are plain C — no GNUstep, just the musl target.
LINUX_SIM_BINS = $(LINUX_BIN_DIR)/xcc-sim-6502 $(LINUX_BIN_DIR)/xcc-sim-68k
$(LINUX_BIN_DIR)/xcc-sim-6502: src/xts/sim6502.c | $(LINUX_BIN_DIR)
	$(LINUX_CC) $(LINUX_BASE_FLAGS) -static-pie -Wall -Wextra -O2 -std=c11 $(VERSION_DEF) -o $@ $< -lm
$(LINUX_BIN_DIR)/xcc-sim-68k: src/xst/sim68k.c | $(LINUX_BIN_DIR)
	$(LINUX_CC) $(LINUX_BASE_FLAGS) -static-pie -Wall -Wextra -O2 -std=c11 $(VERSION_DEF) -o $@ $< -lm

$(LINUX_BIN_DIR):
	@mkdir -p $@

# Pattern rule: build/linux/path/to/foo.o <- path/to/foo.m
# LINUX_EXTRA_CFLAGS is empty by default; set per-target (the TLS objects add it).
$(LINUX_BUILD_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	$(LINUX_CC) $(LINUX_CFLAGS) $(LINUX_EXTRA_CFLAGS) -c -o $@ $<

.PHONY: linux
linux: $(LINUX_BINS) $(LINUX_SIM_BINS)

-include $(sort $(LINUX_OBJS:.o=.d))

# ── Windows cross-build ──────────────────────────────────────────────
# Builds static xtc/xta/xts .exe binaries for x86_64-w64-mingw32 using
# the toolchain under /opt/clang/win64/. Object files land under
# build/win64/ (mirroring the source tree) alongside the linux build
# so they don't collide with the host Darwin build; finished binaries
# and staged runtime/lib resources land under bin/win64/.
#
# Invoke as `make win64`. Requires the cross toolchain under
# /opt/clang/win64 to be installed. The wrapper `x86_64-w64-mingw32-
# clang` here already sources a sensible cfg (libc++ is what the
# recipe wants on Windows), so unlike the linux cross path we keep
# using the wrapper directly.
WIN64_TOOLCHAIN  = /opt/clang/win64
WIN64_SYSROOT    = $(WIN64_TOOLCHAIN)/x86_64-w64-mingw32
WIN64_CC         = $(WIN64_TOOLCHAIN)/bin/x86_64-w64-mingw32-clang

# Objective-C compile flags. `-Ddispatch_STATIC` is mandatory — the
# libdispatch headers default to dllimport otherwise and static
# linking falls apart. `-fconstant-string-class=NXConstantString`
# matches what libs-base was built against; without it, the default
# for Windows + new ABI is NSConstantString and string literals
# reference an undefined class. `-fobjc-runtime=gnustep-2.2` matches
# the runtime ABI the sysroot was built with.
WIN64_OBJCFLAGS  = -Ddispatch_STATIC \
                   -fobjc-runtime=gnustep-2.2 \
                   -fconstant-string-class=NXConstantString \
                   -fblocks -fobjc-arc \
                   -I $(WIN64_SYSROOT)/Local/Library/Headers

WIN64_CFLAGS     = $(WIN64_OBJCFLAGS) \
                   -Wall -Wextra -Wshadow -std=gnu11 \
                   -Wno-unused-parameter -Wno-objc-designated-initializers \
                   $(VERSION_DEF) $(DEPFLAGS) $(XTC_INCLUDES) $(XTA_INCLUDES)

# Static link recipe from /opt/clang/win64/README.md. --whole-archive
# on libgnustep-base/libobjc is mandatory (Obj-C class loaders and
# +load live in archive members the linker would otherwise drop).
# The Windows system libs at the end satisfy synchronisation, TCP,
# COM, and registry calls that libs-base and libdispatch make.
WIN64_LDFLAGS    = -static \
                   -Wl,/ignore:4217 \
                   -Wl,--whole-archive -lgnustep-base -lobjc -Wl,--no-whole-archive \
                   -Wl,--start-group \
                     -ldispatch -lBlocksRuntime \
                     -lxml2 -lsicuuc -lsicuin -lsicudt -lffi -lz -llzma -liconv \
                     -lc++ -lc++abi -lunwind \
                   -Wl,--end-group \
                   -lpthread -lsynchronization -lbcrypt -lws2_32 -lole32 -lshlwapi \
                   -ladvapi32 -luser32 -lkernel32 -lnetapi32

WIN64_BUILD_DIR  = build/win64
WIN64_BIN_DIR    = bin/win64

WIN64IZE = $(addprefix $(WIN64_BUILD_DIR)/,$(1))

#   $(1) binary basename (.exe is appended), $(2) host object list.
define WIN64_BIN_template
WIN64_BINS += $(WIN64_BIN_DIR)/$(1).exe
WIN64_OBJS += $(call WIN64IZE,$(2))
$(WIN64_BIN_DIR)/$(1).exe: $(call WIN64IZE,$(2)) | $(WIN64_BIN_DIR)
	$$(WIN64_CC) $$(WIN64_LDFLAGS) -o $$@ $(call WIN64IZE,$(2))
endef

$(eval $(call WIN64_BIN_template,xcc,$(XTC_OBJS_TRIM)))
$(eval $(call WIN64_BIN_template,xcc-as,$(XTA_OBJS) $(XTA_MODEL_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-fe,$(XTC_FE_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-cg-6502,$(XTCG_6502_OBJS) $(XTA_LIB_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-cg-arm64,$(XTCG_ARM64_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-cg-68k,$(XTCG_68K_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-cg-arm9,$(XTCG_ARM9_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-cg-x86_64,$(XTCG_X8664_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-cg-win64,$(XTCG_WIN64_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-cg-wasm32,$(XTCG_WASM32_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-ln-arm64,$(XTCLN_ARM64_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-ln-x86_64,$(XTCLN_X8664_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-ln-arm9,$(XTCLN_ARM9_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-ln-win64,$(XTCLN_WIN64_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-ln-wasm32,$(XTCLN_WASM32_OBJS)))
$(eval $(call WIN64_BIN_template,xcc-sign,$(XTSIGN_BASE_OBJS)))

# The simulators: `-static` gets a fully static .exe with no CRT DLL dep.
WIN64_SIM_BINS = $(WIN64_BIN_DIR)/xcc-sim-6502.exe $(WIN64_BIN_DIR)/xcc-sim-68k.exe
$(WIN64_BIN_DIR)/xcc-sim-6502.exe: src/xts/sim6502.c | $(WIN64_BIN_DIR)
	$(WIN64_CC) -static -Wall -Wextra -O2 -std=c11 $(VERSION_DEF) -o $@ $<
$(WIN64_BIN_DIR)/xcc-sim-68k.exe: src/xst/sim68k.c | $(WIN64_BIN_DIR)
	$(WIN64_CC) -static -Wall -Wextra -O2 -std=c11 $(VERSION_DEF) -o $@ $<

$(WIN64_BIN_DIR):
	@mkdir -p $@

# Pattern rule: build/win64/path/to/foo.o <- path/to/foo.m
$(WIN64_BUILD_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	$(WIN64_CC) $(WIN64_CFLAGS) -c -o $@ $<

.PHONY: win64
win64: $(WIN64_BINS) $(WIN64_SIM_BINS)

-include $(sort $(WIN64_OBJS:.o=.d))

# ── Distribution archives ────────────────────────────────────────────
# One archive per HOST platform, each the whole toolchain in the same
# layout `make install` produces (bin/ + lib/xc + the vendored link
# pools), rooted at xcc-<plat>-<version>/ so extraction yields one
# self-contained directory. The binaries find lib/xc relative to
# themselves, so no environment or flags are needed after unpacking.
# The arm9 sysroot is deliberately omitted (large, target-specific);
# the downloads page says so.
#
# Archives land in the monorepo's website/downloads/, which is what
# tools/release/deploy-website.sh rsyncs to compile-xc.org. They are
# deliberately NOT inside website/site/ — the Astro build must contain zero
# binary artifacts.
DIST_DIR  ?= ../website/downloads
DIST_STAGE = build/dist

OSX_ARCHIVE   = $(DIST_DIR)/xcc-osx-$(VERSION).tar.bz2
LINUX_ARCHIVE = $(DIST_DIR)/xcc-linux-$(VERSION).tar.bz2
WIN64_ARCHIVE = $(DIST_DIR)/xcc-win64-$(VERSION).zip

# Canned staging sequence: $(1) plat, $(2) source bin dir, $(3) binary suffix,
# $(5) the SELF-HOSTED compiler to ship as `xcc` on this platform. EMPTY means
# that platform cannot build one yet — and then there is no archive, because we
# never ship the Objective-C compiler ("THE GOLDEN RULE"). All three
# platforms have one, so all three archives are cut: XCC_XC_BIN (`-A arm64`),
# XCC_XC_LINUX_BIN (`production-linux`) and XCC_XC_WIN64_BIN
# (`production-win64`). The EMPTY guard below stays: a
# target added later will arrive without a self-hosted build, and it must get
# NO ARCHIVE rather than an Objective-C one.
# $(4) strip tool for the staged copies (empty to skip). The build tree keeps
# its debug info; only the archive is stripped — it halves the cross binaries.
# Refuses a dirty tree: an archive must be reproducible from a commit.
define STAGE_DIST
@if [ -n "$$(git status --porcelain 2>/dev/null)" ]; then \
	echo "dist: tree is dirty — commit first (archives must be cut from a commit)"; exit 1; fi
@rm -rf $(DIST_STAGE)/xcc-$(1)-$(VERSION)
@mkdir -p $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin $(DIST_STAGE)/xcc-$(1)-$(VERSION)/lib/xc
@for b in $(notdir $(INSTALL_BINS)); do \
	$(CP) $(2)/$$b$(3) $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/ || exit 1; done
	@# THE GOLDEN RULE: we never ship the Objective-C compiler.
	@# It bootstraps the xc one and is the reference oracle it is diffed
	@# against; that is all. So `xcc` in an archive is the SELF-HOSTED
	@# binary, exactly as `install` ships it, and the Objective-C build goes
	@# beside it as xcc-bootstrap.
	@#
	@# This swap used to live ONLY in the install recipe, so every archive
	@# `make dist` cut shipped the Objective-C compiler as `xcc` — a
	@# different program from the one `make install` produced and the one
	@# the 40-harness gate validated, carrying a Foundation/libobjc
	@# dependency the self-hosted compiler does not have.
	@if [ -z "$(5)" ]; then \
		echo "dist($(1)): no self-hosted compiler for this platform."; \
		echo "  THE GOLDEN RULE: we never ship the Objective-C build as xcc."; \
		echo "  A platform that cannot build xcc-xc gets NO ARCHIVE until"; \
		echo "  that gap is closed."; \
		exit 1; fi
	@$(CP) $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/xcc$(3) \
	       $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/xcc-bootstrap$(3)
	@$(CP) $(5) $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/xcc$(3)
	@# …and prove it, rather than trusting the copy above. A staged `xcc`
	@# that still links Foundation is the Objective-C build wearing the
	@# right name. Checked on macOS, where otool is the tool to hand; the
	@# cross archives are caught by the $(5) guard above.
	@if [ "$(UNAME_S)" = "Darwin" ] && [ -z "$(3)" ] && \
	   otool -L $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/xcc 2>/dev/null \
	   | grep -q Foundation; then \
		echo "dist($(1)): staged xcc links Foundation — that is the"; \
		echo "  Objective-C compiler. THE GOLDEN RULE forbids shipping it."; \
		exit 1; fi
	@# The SIGNER likewise, mirroring `install` exactly. This swap used to be
	@# missing here, so every archive shipped the Objective-C xcc-sign as
	@# `xcc-sign` while `make install` shipped the xc one — the same
	@# install-vs-dist divergence this file already records fixing for `xcc`.
	@# The engine is host-neutral, so all three platforms get it.
	@if [ -z "$(6)" ]; then \
		echo "dist($(1)): no self-hosted signer for this platform."; \
		echo "  THE GOLDEN RULE: we never ship the Objective-C build as xcc-sign."; \
		exit 1; fi
	@$(CP) $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/xcc-sign$(3) \
	       $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/xcc-sign-bootstrap$(3)
	@$(CP) $(6) $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/xcc-sign$(3)
@if [ -n "$(4)" ]; then $(4) $(DIST_STAGE)/xcc-$(1)-$(VERSION)/bin/*; fi
@for src in $(SUPPORT_SRCS); do \
	dst=$(DIST_STAGE)/xcc-$(1)-$(VERSION)/lib/xc/$${src#support/}; \
	mkdir -p $$(dirname $$dst); $(CP) $$src $$dst; done
@if [ -d "$(X86_64_POOL)" ]; then \
	mkdir -p $(DIST_STAGE)/xcc-$(1)-$(VERSION)/lib/xc/x86_64-sysroot; \
	for f in $(X86_64_POOL_FILES); do \
		$(CP) $(X86_64_POOL)/$$f $(DIST_STAGE)/xcc-$(1)-$(VERSION)/lib/xc/x86_64-sysroot/$$(basename $$f); done; \
else echo "dist: x86-64 musl pool missing at $(X86_64_POOL)"; exit 1; fi
@if [ -d "$(WIN64_POOL)" ]; then \
	mkdir -p $(DIST_STAGE)/xcc-$(1)-$(VERSION)/lib/xc/win64-sysroot; \
	for f in $(WIN64_POOL_FILES); do \
		$(CP) $(WIN64_POOL)/$$f $(DIST_STAGE)/xcc-$(1)-$(VERSION)/lib/xc/win64-sysroot/$$(basename $$f); done; \
else echo "dist: win64 mingw pool missing at $(WIN64_POOL)"; exit 1; fi
@mkdir -p $(DIST_DIR)
endef

$(OSX_ARCHIVE): all production
	$(call STAGE_DIST,osx,$(BIN_DIR),,,$(XCC_XC_BIN),$(XCC_SIGN_XC_BIN))
	@rm -f $@
	tar -cjf $@ -C $(DIST_STAGE) xcc-osx-$(VERSION)
	@echo "dist -> $@"

$(LINUX_ARCHIVE): linux production-linux
	$(call STAGE_DIST,linux,$(LINUX_BIN_DIR),,/opt/homebrew/opt/llvm/bin/llvm-strip,$(XCC_XC_LINUX_BIN),$(XCC_SIGN_XC_LINUX_BIN))
	@rm -f $@
	tar -cjf $@ -C $(DIST_STAGE) xcc-linux-$(VERSION)
	@echo "dist -> $@"

$(WIN64_ARCHIVE): win64 production-win64
	$(call STAGE_DIST,win64,$(WIN64_BIN_DIR),.exe,/opt/homebrew/opt/llvm/bin/llvm-strip,$(XCC_XC_WIN64_BIN),$(XCC_SIGN_XC_WIN64_BIN))
	@rm -f $@
	cd $(DIST_STAGE) && zip -qr $(abspath $@) xcc-win64-$(VERSION)
	@echo "dist -> $@"

.PHONY: dist dist-osx dist-linux dist-win64
dist-osx:   $(OSX_ARCHIVE)
dist-linux: $(LINUX_ARCHIVE)
dist-win64: $(WIN64_ARCHIVE)
dist:       dist-osx dist-linux dist-win64

endif   # macOS-only cross-builds + distribution archives

# ── Fixture sweep ────────────────────────────────────────────────────
# Compiles every fixture under tests/fixtures/ across the configured
# target/opt matrix, runs it under `bin/xts -d`, and checks the output
# for FAIL lines / missing DONE terminators. Fixtures are self-
# verifying (they print `T<n> PASS/FAIL` via Stdio.printf).
fixtures: $(XTC_BIN) $(XTA_BIN) $(SIM_BIN)
	@./tests/run_fixtures.sh

clean:
	rm -f $(XTC_OBJS) $(XTA_OBJS) $(XTA_LIB_OBJS) $(TEST_OBJS)
	rm -f $(XTC_OBJS:.o=.d) $(XTA_OBJS:.o=.d) $(XTA_LIB_OBJS:.o=.d) $(TEST_OBJS:.o=.d)
	rm -f $(STANDALONE_TESTS:.m=.o) $(STANDALONE_TESTS:.m=.d)
	rm -rf bin build

# ── Website distribution ─────────────────────────────────────────────
# `make dist` (above) writes the binary archives into the website's
# downloads folder.  Packaging and deploying the rendered site
# ── Differential fuzzer ──────────────────────────────────────────────
# Generates random valid programs and runs each on every backend AND at two
# -O levels; any disagreement is a bug (the backends are each other's oracle).
# FUZZ_N programs from FUZZ_START, so a campaign can resume where one ended
# without re-testing seeds already known clean.
.PHONY: fuzz
FUZZ_N ?= 200
FUZZ_START ?= 1
FUZZ_ONLY ?= arm64,xt6502,m68k,wasm32
FUZZ_OPT ?= 0,3
fuzz: all
	python3 tests/fuzz/fuzz.py -n $(FUZZ_N) --start $(FUZZ_START) \
	        --only $(FUZZ_ONLY) --opt $(FUZZ_OPT) $(FUZZ_ARGS)

# The website is built and published by tools/release/deploy-website.sh.

.PHONY: all clean test perf fuzz fixtures

# ── x86-64 assembler oracle-diff (self-hosted Linux last stage) ──────────
# Byte-compares XAX86_64Assembler against clang. Not part of `make test`
# (needs clang + objdump at runtime); run explicitly.
ELFOBJDUMP_BIN = $(BIN_DIR)/elfobjdump
.PHONY: elfobjdump
elfobjdump: $(ELFOBJDUMP_BIN)
$(ELFOBJDUMP_BIN): selfhost/tools/elfobjdump.xc selfhost/asm/ElfObject.xc \
                   selfhost/asm/ArArchive.xc $(XTC_BIN) | $(BIN_DIR)
	@$(XTC_BIN) -A arm64 -H . -I selfhost/asm -o $@ selfhost/tools/elfobjdump.xc

ORACLE_COFFOBJ_BIN = $(BIN_DIR)/oracle-coffobj
.PHONY: oracle-coffobj
oracle-coffobj: $(ORACLE_COFFOBJ_BIN)
$(ORACLE_COFFOBJ_BIN): tests/link-coffobj/oracle-diff/harness.m \
                       src/xtc/link/XTPEWriter.m src/xtc/link/XTArArchive.m | $(BIN_DIR)
	$(CC) $(CFLAGS) -I src/xtc/link -I src/xtc/asm/x86_64 $(LDFLAGS) -o $@ $^

COFFOBJDUMP_BIN = $(BIN_DIR)/coffobjdump
.PHONY: coffobjdump
coffobjdump: $(COFFOBJDUMP_BIN)
$(COFFOBJDUMP_BIN): selfhost/tools/coffobjdump.xc selfhost/asm/CoffObject.xc \
                    selfhost/asm/ElfObject.xc selfhost/asm/ArArchive.xc $(XTC_BIN) | $(BIN_DIR)
	@$(XTC_BIN) -A arm64 -H . -I selfhost/asm -o $@ selfhost/tools/coffobjdump.xc

ORACLE_ELFOBJ_BIN = $(BIN_DIR)/oracle-elfobj
.PHONY: oracle-elfobj
oracle-elfobj: $(ORACLE_ELFOBJ_BIN)
$(ORACLE_ELFOBJ_BIN): tests/link-elfobj/oracle-diff/harness.m \
                      src/xtc/link/XTElfWriter.m src/xtc/link/XTArArchive.m | $(BIN_DIR)
	$(CC) $(CFLAGS) -I src/xtc/link -I src/xtc/asm/x86_64 $(LDFLAGS) -o $@ $^

ORACLE_X8664_BIN = $(BIN_DIR)/oracle-x86_64
.PHONY: oracle-x86_64
oracle-x86_64: $(ORACLE_X8664_BIN)
$(ORACLE_X8664_BIN): tests/asm-x86_64/oracle-diff/harness.m \
                     src/xtc/asm/x86_64/XAX86_64Assembler.m | $(BIN_DIR)
	$(CC) $(CFLAGS) -I src/xtc/asm/x86_64 $(LDFLAGS) -o $@ $^

# The self-hosted Linux path, end to end. Each script skips cleanly when no
# Linux host is reachable (XTC_LINUX_HOST in build.env).
#   selfhost-x86_64        — the guards: raw-syscall ELF, then library + app
#   selfhost-x86_64-corpus — the AUTHORITATIVE number: the same sweep `make
#     corpus` runs, with its x86-64 leg routed through the in-house toolchain.
#     Same fixture selection and oracles as the clang run, so the two counts are
#     directly comparable. tests/asm-x86_64/selfhost-corpus.sh is a lighter
#     standalone harness for iteration; its fixture filter is its own, so its
#     count is NOT comparable with `make corpus`.
.PHONY: selfhost-x86_64 selfhost-x86_64-corpus
selfhost-x86_64: $(BIN_DIR)/elf-smoke $(XTC_BIN) $(XTCLN_X8664_BIN) $(XTCG_X8664_BIN)
	@./tests/asm-x86_64/elf-run.sh
	@./tests/asm-x86_64/selfhost-lib.sh

# The self-hosted Windows path (Wine-gated): xtc → XTPEWriter → run under Wine.
.PHONY: selfhost-win64
selfhost-win64: $(XTC_BIN) $(XTCLN_WIN64_BIN) $(XTCG_WIN64_BIN)
	@./tests/asm-x86_64/selfhost-win64.sh

# crossmatrix — one Mac builds the same program for arm64/x86_64/win64, all
# self-hosted, and checks the three agree. The "on macOS" row of the host×target
# matrix (private:docs/Design/native-toolchain.md §14).
.PHONY: crossmatrix
crossmatrix: $(XTC_BIN) $(XTCLN_ARM64_BIN) $(XTCLN_X8664_BIN) $(XTCLN_WIN64_BIN) \
             $(XTCG_ARM64_BIN) $(XTCG_X8664_BIN) $(XTCG_WIN64_BIN)
	@./tests/asm-x86_64/crossmatrix.sh

# crossmatrix-linux — the on-Linux row: the compiler RUNNING on the Linux host
# (provisioned via tools/provision-gnustep-linux.sh) builds mac/linux/win targets,
# each run on its runner. Driven from here so it can run the Mach-O and PE.
.PHONY: crossmatrix-linux
crossmatrix-linux:
	@./tests/asm-x86_64/crossmatrix-linux.sh

# crossmatrix-win — the on-Windows row: the compiler RUNNING on Windows (built via
# tools/winbuild.bat) builds mac/linux/win targets, each run on its runner.
.PHONY: crossmatrix-win
crossmatrix-win:
	@./tests/asm-x86_64/crossmatrix-win.sh

# determinism — the compiler must be a deterministic function of its input:
# compile every fixture twice in separate processes and byte-compare. Guards the
# 3-stage bootstrap precondition (private:docs/Design/self-hosting.md §5).
.PHONY: determinism
determinism:
	@./tests/determinism.sh -A arm64

# selfhost — the differential harnesses for the xtc-language front end
# (private:docs/Design/self-hosting.md M4-M6). Each builds its tool with xtc, runs both
# implementations over every .xc source in the tree, and compares byte for byte:
#
#   lexer-diff   token streams     (xtc-fe --dump-tokens is the oracle)
#   pp-diff      preprocessed text (--dump-pp)
#   ast-diff     parsed trees      (--dump-ast)
#
# Fast — about a minute each — and the right first check after touching
# anything under selfhost/.
.PHONY: selfhost
selfhost: $(XTC_BIN) $(XTC_FE_BIN)
	@./selfhost/tools/lexer-diff.sh
	@./selfhost/tools/pp-diff.sh
	@./selfhost/tools/ast-diff.sh

# selfhost-ir — the WHOLE front end, source to IR text, against `xtc-fe -o`.
# ir-diff is the 53 hand-written fixtures; irwide-diff is every .xc in the tree
# at the default target; fe-diff runs the DROP-IN front end the way the driver
# runs the real one, at a named target (arm64 by default). Slower — a few
# minutes each — and the number that decides whether the port can be dropped in.
.PHONY: selfhost-ir
selfhost-ir: $(XTC_BIN) $(XTC_FE_BIN)
	@./selfhost/tools/ir-diff.sh
	@./selfhost/tools/irwide-diff.sh
	@./selfhost/tools/fe-diff.sh arm64
	@./selfhost/tools/fe-diff.sh x86_64
	@./selfhost/tools/fe-diff.sh atarist
	@./selfhost/tools/fe-diff.sh arm9
	@./selfhost/tools/fe-diff.sh win64
	@./selfhost/tools/irrt-diff.sh arm64
	@./selfhost/tools/a9-diff.sh

# a9-pure — the ported toolchain with nothing else in it: every fixture in
# tests/asm-arm32 built by selfhost/ alone (front end, back end, assembler,
# linker) and RUN under the XTOS loader on qemu, output compared.
.PHONY: a9-pure
a9-pure: $(XTC_BIN)
	@./selfhost/tools/as9-diff.sh
	@./selfhost/tools/a9-run.sh

# bootstrap — M7. Build the front end with the Objective-C toolchain, then
# with itself, then with that: stage2 == stage3 is the fixed point.
.PHONY: bootstrap
bootstrap: $(XTC_BIN) $(XTC_FE_BIN) $(XTCG_ARM64_BIN)
	@./selfhost/tools/bootstrap.sh

# wincorpus — the deterministic fixture corpus through the Windows-native
# compiler (win64 self-host). Needs the compiler built on the Windows host.
.PHONY: wincorpus
wincorpus:
	@./tests/asm-x86_64/wincorpus.sh
selfhost-x86_64-corpus: $(CORPUS_BIN) $(XTC_BIN) $(XTCLN_X8664_BIN) $(XTCG_X8664_BIN)
	@XTC_X86_SELFHOST=1 ./$(CORPUS_BIN)

# End-to-end ELF smoke driver: our x86-64 encoder + our ELF writer produce a
# runnable Linux binary with no Linux tooling at all. Run the output on a
# Linux host (tests/asm-x86_64/elf-run.sh drives it over ssh).
.PHONY: elf-smoke
elf-smoke: $(BIN_DIR)/elf-smoke
$(BIN_DIR)/elf-smoke: tests/asm-x86_64/elf-smoke.m \
                      src/xtc/asm/x86_64/XAX86_64Assembler.m \
                      src/xtc/link/XTElfWriter.m src/xtc/link/XTArArchive.m | $(BIN_DIR)
	$(CC) $(CFLAGS) -I src/xtc/asm/x86_64 -I src/xtc/link $(LDFLAGS) -o $@ $^
