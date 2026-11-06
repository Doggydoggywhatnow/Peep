# Peep — build
#
#   make            Linux binary   build/peep
#   make exe        Windows binary build/Peep.exe   (mingw-w64 cross compiler)
#   make appimage   build/Peep-x86_64.AppImage
#   make pure       Linux, zero C: native WAV decoder only
#   make all        everything

NASM     ?= nasm
CC       ?= gcc
MINGW    ?= x86_64-w64-mingw32-gcc
WINDRES  ?= x86_64-w64-mingw32-windres
CODEC_CFLAGS = -Os -fno-asynchronous-unwind-tables -fno-stack-protector -w

B := build
CORE_DEPS := src/abi.inc src/font.inc

.PHONY: linux exe pure appimage all clean
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
$(B)/codecs.o: src/codecs.c | $(B)
	$(CC) $(CODEC_CFLAGS) -c $< -o $@

LINUX_LIBS := -lX11 -lasound -lm
$(B)/peep: $(B)/core.o $(B)/linux.o $(B)/codecs.o
	$(CC) -no-pie -s -Wl,--as-needed -Wl,--gc-sections -o $@ $^ $(LINUX_LIBS)
$(B)/peep-pure: $(B)/core_pure.o $(B)/linux.o
	$(CC) -no-pie -s -Wl,--as-needed -o $@ $^ -lX11 -lasound
pure: $(B)/peep-pure

# ---- Windows ---------------------------------------------------------------
$(B)/core.obj: src/core.asm $(CORE_DEPS) | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/win32.obj: src/win32.asm src/abi.inc | $(B)
	$(NASM) -f win64 -DWIN64 -Isrc/ $< -o $@
$(B)/codecs.obj: src/codecs.c | $(B)
	$(MINGW) $(CODEC_CFLAGS) -c $< -o $@
$(B)/res.obj: res/peep.rc res/peep.ico | $(B)
	$(WINDRES) $< -O coff -o $@
$(B)/Peep.exe: $(B)/core.obj $(B)/win32.obj $(B)/codecs.obj $(B)/res.obj
	$(MINGW) -s -mwindows -static-libgcc -Wl,--gc-sections -o $@ $^ \
		-lshell32 -lwinmm -lgdi32 -luser32 -lkernel32
exe: $(B)/Peep.exe

# ---- AppImage --------------------------------------------------------------
# The AppImage is assembled by hand: the official type-2 runtime
# (https://github.com/AppImage/type2-runtime) followed by a squashfs of AppDir.
# Point RUNTIME at a downloaded runtime-x86_64.
RUNTIME ?= runtime-x86_64
$(B)/Peep-x86_64.AppImage: $(B)/peep res/peep.desktop res/peep.png res/AppRun
	rm -rf $(B)/AppDir && mkdir -p $(B)/AppDir/usr/bin
	cp $(B)/peep $(B)/AppDir/usr/bin/peep
	cp res/AppRun $(B)/AppDir/AppRun && chmod +x $(B)/AppDir/AppRun
	cp res/peep.desktop res/peep.png $(B)/AppDir/
	ln -sf peep.png $(B)/AppDir/.DirIcon
	rm -f $(B)/peep.squashfs
	mksquashfs $(B)/AppDir $(B)/peep.squashfs -root-owned -noappend -comp zstd -quiet
	cat $(RUNTIME) $(B)/peep.squashfs > $@
	chmod +x $@
	rm -f $(B)/peep.squashfs
appimage: $(B)/Peep-x86_64.AppImage

all: linux pure exe appimage

clean:
	rm -rf $(B)
