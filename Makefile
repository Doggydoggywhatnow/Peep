# Peep — build
#
#   make            Linux binary   build/peep
#   make exe        Windows binary build/Peep.exe   (mingw-w64 cross compiler)
#   make appimage   build/Peep-x86_64.AppImage
#   make deb        build/peep_<version>_amd64.deb (Debian / Ubuntu package)
#   make pure       Linux, zero C: native WAV decoder only
#   make musl       build/peep-musl for musl Linux (Void, Alpine); needs musl-gcc
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

.PHONY: linux exe pure musl appimage deb test all clean
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
# The decoders, pure assembly: the playback kernel with the built-in 16-bit PCM
# WAV decoder (src/peep.asm), the other WAV formats (src/wav.asm) and native
# FLAC (src/flac.asm).
$(B)/dec.o: src/peep.asm src/abi.inc | $(B)
	$(NASM) -f elf64 -Isrc/ $< -o $@
$(B)/flac.o: src/flac.asm src/abi.inc | $(B)
	$(NASM) -f elf64 -Isrc/ $< -o $@
$(B)/wav.o: src/wav.asm src/abi.inc | $(B)
	$(NASM) -f elf64 -Isrc/ $< -o $@
$(B)/codecs.o: src/codecs.c | $(B)
	$(CC) $(CODEC_CFLAGS) -c $< -o $@

LINUX_LIBS := -lX11 -lXext -lasound -lm
$(B)/peep: $(B)/core.o $(B)/meta.o $(B)/gfx.o $(B)/linux.o $(B)/dec.o $(B)/flac.o $(B)/wav.o $(B)/codecs.o
	$(CC) -no-pie -s -Wl,--as-needed -Wl,--gc-sections -o $@ $^ $(LINUX_LIBS)
$(B)/peep-pure: $(B)/core_pure.o $(B)/meta.o $(B)/gfx_pure.o $(B)/linux.o $(B)/dec.o $(B)/flac.o $(B)/wav.o
	$(CC) -no-pie -s -Wl,--as-needed -o $@ $^ -lX11 -lXext -lasound
pure: $(B)/peep-pure

# ---- musl Linux (Void, Alpine) -----------------------------------------------
# The same program linked with musl-gcc, so it asks for musl's loader instead of
# glibc 2.34. Building needs no musl copy of libX11 or libasound: empty stand-ins
# with the right sonames are made from the names listed here, and on the target
# the real libraries answer to them. (The link fails if a name is missing, so a
# new X11 or ALSA call must be added to these lists.)
MUSLCC ?= musl-gcc
M := $(B)/musl
SYMS_X11 := XChangeProperty XConnectionNumber XConvertSelection XCreateBitmapFromData XCreateImage XCreatePixmapCursor XCreateSimpleWindow XDefaultDepth XDefaultGC XDefaultScreen XDefaultVisual XDefineCursor XDisplayHeight XDisplayWidth XFlush XFree XGetWindowProperty XInternAtoms XLookupKeysym XMapWindow XNextEvent XOpenDisplay XPending XPutImage XResizeWindow XRootWindow XSelectInput XSendEvent XSetClassHint XSetWMNormalHints XSetWMProtocols XSetWindowBackgroundPixmap XStoreName XUndefineCursor XUngrabPointer
SYMS_XEXT := XSyncCreateCounter XSyncInitialize XSyncQueryExtension XSyncSetCounter
SYMS_ASOUND := snd_pcm_avail_update snd_pcm_close snd_pcm_delay snd_pcm_drain snd_pcm_drop snd_pcm_open snd_pcm_prepare snd_pcm_recover snd_pcm_set_params snd_pcm_state snd_pcm_wait snd_pcm_writei
$(M):
	mkdir -p $(M)
$(M)/libX11.so.6: | $(M)
	printf 'void %s(void){}\n' $(SYMS_X11) | $(MUSLCC) -shared -nostdlib -x c - -Wl,-soname,libX11.so.6 -o $@
$(M)/libXext.so.6: | $(M)
	printf 'void %s(void){}\n' $(SYMS_XEXT) | $(MUSLCC) -shared -nostdlib -x c - -Wl,-soname,libXext.so.6 -o $@
$(M)/libasound.so.2: | $(M)
	printf 'void %s(void){}\n' $(SYMS_ASOUND) | $(MUSLCC) -shared -nostdlib -x c - -Wl,-soname,libasound.so.2 -o $@
# Same assembly as the glibc build; MUSL gives new threads a bigger stack (musl's
# default is 128 KB). The C is built without glibc's fortify wrappers.
$(M)/linux.o: src/linux.asm src/abi.inc | $(M)
	$(NASM) -f elf64 -DMUSL -Isrc/ $< -o $@
$(M)/codecs.o: src/codecs.c | $(M)
	$(MUSLCC) $(CODEC_CFLAGS) -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -c $< -o $@
$(B)/peep-musl: $(B)/core.o $(B)/meta.o $(B)/gfx.o $(M)/linux.o $(B)/dec.o $(B)/flac.o $(B)/wav.o $(M)/codecs.o $(M)/libX11.so.6 $(M)/libXext.so.6 $(M)/libasound.so.2
	$(MUSLCC) -no-pie -s -Wl,--as-needed -Wl,--gc-sections -o $@ $^ -lm
musl: $(B)/peep-musl

# ---- Windows ---------------------------------------------------------------
$(B)/core.obj: src/core.asm $(CORE_DEPS) | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/win32.obj: src/win32.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/meta.obj: src/meta.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/gfx.obj: src/gfx.asm $(CORE_DEPS) README.md | $(B)
	$(NASM) -f win64 -DWIN64 $(VERFLAG) -Isrc/ $< -o $@
$(B)/dec.obj: src/peep.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/flac.obj: src/flac.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/wav.obj: src/wav.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/codecs.obj: src/codecs.c | $(B)
	$(MINGW) $(CODEC_CFLAGS) -c $< -o $@
$(B)/res.obj: res/peep.rc res/peep.ico | $(B)
	$(WINDRES) $< -O coff -o $@
$(B)/Peep.exe: $(B)/core.obj $(B)/meta.obj $(B)/gfx.obj $(B)/win32.obj $(B)/dec.obj $(B)/flac.obj $(B)/wav.obj $(B)/codecs.obj $(B)/res.obj
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

# ---- Tests -----------------------------------------------------------------
test: $(B)/peep
	python3 tests/run.py

all: linux pure exe appimage deb

clean:
	rm -rf $(B)
