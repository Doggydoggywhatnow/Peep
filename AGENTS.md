# AGENTS.md

Guidance for AI coding agents (and people) working on Peep. Read the README's
**Philosophy** section first: it is the spec for what belongs in this project.

## What Peep is

A music player that is just a screen: the album cover fills the window, the
controls show only under the pointer, and nothing leaves the machine.
Hand-written x86-64 assembly for Linux (X11 + ALSA) and Windows (Win32 +
waveOut), plus one small C shim over public-domain decoder libraries.
Released under the Unlicense.

## Rules from the owner

* **Ask before assuming scope.** Honor standing rules: privacy (no network
  code, no telemetry, nothing written to disk), never remove features without
  being told to, keep Linux and Windows both supported.
* **Version bumps.** Any change to what ships (program, packages, README,
  CHANGELOG, license) is a patch bump (0.2.12 -> 0.2.13). **Do not go to 1.0.0
  unless the owner says so.** Contributor-only changes (this file, `tests/`)
  don't need one.
* **Check before pushing** `main`: `git status`, `git log -3`,
  `git fetch origin main`. Never force-push or rewrite history without the
  owner's say-so.
* **Be honest about what wasn't tested.** The Windows build cannot be run
  from Linux and has never been run by the agents that built it. Say so.
* Keep the repo free of shell scripts (`res/AppRun` is a symlink on purpose)
  and keep GitHub's language bar honest: the Makefile and `tests/` are marked
  in `.gitattributes`. Don't add other languages.

## Layout

```
src/abi.inc     calling-convention glue: one source, two ABIs (read it first)
src/core.asm    playlist, player thread, mixer, cover worker thread, input
src/gfx.asm     scaling, overlay, text, hover/fade, clock scheduling
src/meta.asm    tag parsing (ID3, FLAC, Ogg, WAV)
src/linux.asm   X11 window, ALSA, drag and drop, resize sync, startup order
src/win32.asm   Win32 window, waveOut, same behaviours
src/codecs.c    the only C: decoders, image and font loading, MP3 seek index
tests/          test suite (see tests/README.md)
res/            desktop file, icons, Windows resources, .deb metadata
releases/       the current build of each download (replace, don't accumulate)
```

## Build and test

```sh
make            # build/peep
make exe        # build/Peep.exe (mingw-w64)
make appimage RUNTIME=/path/to/runtime-x86_64
make deb        # version is read from the README's first line
make test       # ~2 minutes; builds the helpers and runs every check
```

Run `make test` after any change to `src/`. Add a check to `tests/run.py` for
behaviour you fix or add (and confirm it fails on the old build:
`PEEP_BIN=/path/to/old/peep python3 tests/run.py <check>`). Tests need no
sound card or window manager; see `tests/README.md`.

## Assembly conventions (these have caused real bugs)

* Every function is `FUNC name, locals` ... `RET_`; it saves all callee-saved
  registers of both ABIs. Assemble for all targets: `-f elf64`,
  `-f win64 -DWIN64` and `-f elf64 -DPURE`.
* **Argument registers differ per ABI.** Never keep a value in `rcx`, `rdx`,
  `rdi`, `rsi`, `r8`, `r9` across argument setup: on Linux `A4` is `rcx`.
  Use `rbx`, `r12`-`r15` or a local, or `r10`/`r11` as scratch.
* **`xmm6`-`xmm15` are callee-saved on Windows.** Use `xmm0`-`xmm5` in leaf
  code or save and restore the others.
* Stack arguments: use `SARG(n)` / `SET5` / `SET6`, never raw offsets.
* The platform layer is the `plat_*` functions (audio, map file, thread,
  time, wake). Behaviour must change in `linux.asm` and `win32.asm` together.

## Threads and shared state

* **UI thread** (`main` / `wndproc`): events, drawing. **Player thread**
  (`core_player`): decode, mix, audio. **Cover worker**: decodes one cover,
  joined before the next starts.
* They share plain variables; `lock` the read-modify-writes. The player
  tells the UI something changed with `plat_wake`, and **a wake must redraw**
  (it once didn't).
* `cmd_seek`: the UI adds, the player subtracts *after* moving `st_pos`; the
  clock shows `st_pos + cmd_seek` (`disp_pos`), so keys register instantly
  and the display never jumps back. Keep that order.
* Redraws are scheduled, not polled: `core_next_wake` / `core_tick_needed`.
  While paused Peep must not wake at all.

## Releasing

1. Change the code and run `make test`. Fix failures; don't skip them.
2. Bump the version everywhere it appears. `grep -rn "0.2.12\|0,2,12" .`:
   the README title and download table, `res/peep.rc` (**both** the numeric
   `FILEVERSION`/`PRODUCTVERSION` and the text `FileVersion`; the numeric
   ones were once forgotten), and `CHANGELOG.md`.
3. Add a CHANGELOG entry at the top, in plain language a user would
   understand: what changed and why.
4. Build the three downloads and smoke-test the ones you can: `make exe`,
   `make appimage RUNTIME=...`, `make deb` (install it, run it, remove it).
5. In `releases/`, `git rm` the previous version's files and add the new ones
   (`Peep-X.Y.Z-x86_64.AppImage`, `Peep-X.Y.Z.exe`, `peep_X.Y.Z_amd64.deb`).
6. Review `git diff --cached --stat` (no build junk, no secrets, no personal
   paths), commit, then push to `main`.
7. GitHub tags/releases may not be creatable from your environment. If not,
   say so and give the owner the exact commands.
8. Tell the owner what changed and what is untested or still open.

## Pitfalls

* `build/` is git-ignored build output; don't commit it. Python caches too.
* The README's first line, `# Peep X.Y.Z`, is the source of the version for the
  `.deb` and for the text the **V** key shows (the Makefile passes it to
  `gfx.asm`). Change it first and rebuild.
* Tests that act as a window manager must grant map *and* resize requests, or
  Peep's window stays the wrong size.
* Measure before optimizing and keep numbers in the CHANGELOG; the decoders
  were already negligible (about 0.05% of a core), so `-Os` stays.
