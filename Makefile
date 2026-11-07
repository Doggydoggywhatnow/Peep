# Peep — build
#
#   make            Linux binary   build/peep
#   make exe        Windows binary build/Peep.exe   (mingw-w64 cross compiler)
#   make appimage   build/Peep-x86_64.AppImage
#   make deb        build/peep_<version>_amd64.deb (Debian / Ubuntu package)
#   make pure       Linux, zero C: native WAV decoder only
#   make test       run the test suite (tests/README.md)
#   make all        everything

NASM     ?= nasm
CC       ?= gcc
MINGW    ?= x86_64-w64-mingw32-gcc
WINDRES  ?= x86_64-w64-mingw32-windres
CODEC_CFLAGS = -Os -fno-asynchronous-unwind-tables -fno-stack-protector -w

B := build
# The version comes from the README title ("# Peep X.Y.Z"): the .deb uses it, and
# gfx.asm shows it when V is pressed.
VERSION := $(shell sed -n '1s/^# Peep //p' README.md)
VERFLAG = -DPEEP_VERSION='"$(VERSION)"'
CORE_DEPS := src/abi.inc src/font.inc

.PHONY: linux exe pure appimage deb test all clean
linux: $(B)/peep

$(B):
	mkdir -p $(B)

# ---- Linux -----------------------------------------------------------------
$(B)/core.o: src/core.asm $(CORE_DEPS) | $(B)
	$(NASM) -f elf64 -Isrc/ $< -o $@
$(B)/core_pure.o: src/core.asm $(CORE_DEPS) | $(B)
	$(NASM) -f elf64 -DPURE -Isrc/ $< -o $@
$(B)/linux.o: src/linux.asm src/abi.inc | $(B)
	$(NASM) -f elf64 -Isrc/ $< -o $@
$(B)/meta.o: src/meta.asm src/abi.inc | $(B)
	$(NASM) -f elf64 -Isrc/ $< -o $@
$(B)/gfx.o: src/gfx.asm $(CORE_DEPS) README.md | $(B)
	$(NASM) -f elf64 $(VERFLAG) -Isrc/ $< -o $@
$(B)/gfx_pure.o: src/gfx.asm $(CORE_DEPS) README.md | $(B)
	$(NASM) -f elf64 -DPURE $(VERFLAG) -Isrc/ $< -o $@
$(B)/codecs.o: src/codecs.c | $(B)
	$(CC) $(CODEC_CFLAGS) -c $< -o $@

LINUX_LIBS := -lX11 -lXext -lasound -lm
$(B)/peep: $(B)/core.o $(B)/meta.o $(B)/gfx.o $(B)/linux.o $(B)/codecs.o
	$(CC) -no-pie -s -Wl,--as-needed -Wl,--gc-sections -o $@ $^ $(LINUX_LIBS)
$(B)/peep-pure: $(B)/core_pure.o $(B)/meta.o $(B)/gfx_pure.o $(B)/linux.o
	$(CC) -no-pie -s -Wl,--as-needed -o $@ $^ -lX11 -lXext -lasound
pure: $(B)/peep-pure

# ---- Windows ---------------------------------------------------------------
$(B)/core.obj: src/core.asm $(CORE_DEPS) | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/win32.obj: src/win32.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/meta.obj: src/meta.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/gfx.obj: src/gfx.asm $(CORE_DEPS) README.md | $(B)
	$(NASM) -f win64 -DWIN64 $(VERFLAG) -Isrc/ $< -o $@
$(B)/codecs.obj: src/codecs.c | $(B)
	$(MINGW) $(CODEC_CFLAGS) -c $< -o $@
$(B)/res.obj: res/peep.rc res/peep.ico | $(B)
	$(WINDRES) $< -O coff -o $@
$(B)/Peep.exe: $(B)/core.obj $(B)/meta.obj $(B)/gfx.obj $(B)/win32.obj $(B)/codecs.obj $(B)/res.obj
	$(MINGW) -s -mwindows -static-libgcc -Wl,--gc-sections -o $@ $^ \
		-lshell32 -lwinmm -lgdi32 -luser32 -lkernel32
exe: $(B)/Peep.exe

# ---- AppImage --------------------------------------------------------------
# The AppImage is assembled by hand: the official type-2 runtime
# (https://github.com/AppImage/type2-runtime) followed by a squashfs of AppDir.
# Point RUNTIME at a downloaded runtime-x86_64.
RUNTIME ?= runtime-x86_64
$(B)/Peep-x86_64.AppImage: $(B)/peep res/peep.desktop res/peep.png
	rm -rf $(B)/AppDir && mkdir -p $(B)/AppDir/usr/bin
	cp $(B)/peep $(B)/AppDir/usr/bin/peep
	ln -sf usr/bin/peep $(B)/AppDir/AppRun
	cp res/peep.desktop res/peep.png $(B)/AppDir/
	ln -sf peep.png $(B)/AppDir/.DirIcon
	rm -f $(B)/peep.squashfs
	mksquashfs $(B)/AppDir $(B)/peep.squashfs -root-owned -noappend -comp zstd -quiet
	cat $(RUNTIME) $(B)/peep.squashfs > $@
	chmod +x $@
	rm -f $(B)/peep.squashfs
appimage: $(B)/Peep-x86_64.AppImage

# ---- Debian / Ubuntu package ----------------------------------------------
DEB := $(B)/peep_$(VERSION)_amd64.deb
$(DEB): $(B)/peep res/peep.desktop res/peep.png res/copyright CHANGELOG.md
	rm -rf $(B)/debroot
	install -Dm755 $(B)/peep $(B)/debroot/usr/bin/peep
	install -Dm644 res/peep.desktop $(B)/debroot/usr/share/applications/peep.desktop
	install -Dm644 res/peep.png $(B)/debroot/usr/share/icons/hicolor/256x256/apps/peep.png
	install -Dm644 res/copyright $(B)/debroot/usr/share/doc/peep/copyright
	gzip -9n < CHANGELOG.md > $(B)/debroot/usr/share/doc/peep/changelog.gz
	mkdir -p $(B)/debroot/DEBIAN
	sed -e 's/@VERSION@/$(VERSION)/' \
	    -e "s/@SIZE@/$$(du -sk $(B)/debroot/usr | cut -f1)/" \
	    res/deb-control > $(B)/debroot/DEBIAN/control
	dpkg-deb --root-owner-group -Zxz --build $(B)/debroot $@
deb: $(DEB)

# ---- ARM64 (the arm64 branch) --------------------------------------------------
# lib-Peep's ARM64 WAV + FLAC decoders (pure assembly, GNU as) and a small test
# player. On an ARM64 machine:   make a64      (needs as, gcc, libx11-dev, libasound2-dev)
# Cross-build / test from x86-64: make a64-test CROSS=aarch64-linux-gnu-  (uses qemu-aarch64)
CROSS ?=
A64AS ?= $(CROSS)as
A64CC ?= $(CROSS)gcc
A64OBJS := $(B)/peep_a64.o $(B)/flac_a64.o
ifneq (,$(filter aarch64 arm64,$(shell uname -m)))
QEMU ?=
else
QEMU ?= qemu-aarch64
endif
$(B)/%_a64.o: arm64/%.s arm64/abi_a64.inc | $(B)
	$(A64AS) -I arm64 $< -o $@
$(B)/peep-a64: arm64/player.c arm64/peep.h $(A64OBJS)
	$(A64CC) -O2 -Wall -o $@ arm64/player.c $(A64OBJS) -lX11 -lasound -lpthread
$(B)/peepdump_a64: arm64/tools/peepdump.c arm64/peep.h $(A64OBJS)
	$(A64CC) -static -O2 -DNO_DR -o $@ arm64/tools/peepdump.c $(A64OBJS)
$(B)/fuzz_a64: arm64/tools/fuzz.c arm64/peep.h $(A64OBJS)
	$(A64CC) -static -O1 -g -o $@ arm64/tools/fuzz.c $(A64OBJS)
$(B)/run_a64.sh: $(B)/peepdump_a64
	printf '#!/bin/sh\nexec $(QEMU) $(CURDIR)/$(B)/peepdump_a64 "$$@"\n' > $@; chmod +x $@
a64: $(B)/peep-a64
SEEDDIR := $(B)/seeds
$(SEEDDIR): arm64/tools/mkflac.py
	mkdir -p $@ && for s in 1 10 13 15 17 19; do python3 arm64/tools/mkflac.py --gen $@/s$$s --seed $$s >/dev/null; done
# The decoder test suites: WAV variants, 120 random FLAC streams checked against ground truth,
# and a mutation fuzz run. Needs python3 + numpy.
a64-test: $(B)/run_a64.sh $(B)/fuzz_a64 $(SEEDDIR)
	python3 arm64/tools/testwav.py $(B)/run_a64.sh
	python3 arm64/tools/mkflac.py --run 120 --seed 1 --tool $(B)/run_a64.sh
	$(QEMU) $(B)/fuzz_a64 100000 $(SEEDDIR)/s1.flac $(SEEDDIR)/s10.flac $(SEEDDIR)/s13.flac $(SEEDDIR)/s15.flac $(SEEDDIR)/s17.flac $(SEEDDIR)/s19.flac
.PHONY: a64 a64-test

# ---- Tests -----------------------------------------------------------------
test: $(B)/peep
	python3 tests/run.py

all: linux pure exe appimage deb

clean:
	rm -rf $(B)
