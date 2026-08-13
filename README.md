# vddhx

Visual DDHX: a graphical port of the [ddhx](https://github.com/dd86k/ddhx) hex editor on
SDL3 and [ddui](https://github.com/dd86k/ddui), while using the same robust document core as ddhx.

Tabs and splits, byte-class colouring, a minimap, ddhx's find and goto syntax,
bookmarks, byte-for-byte compare, and an omnibar over the lot.

![vddhx: two panes and the omnibar](assets/screenshot.png)

Status: 0.1.0, in development.

## Building

Needs a D compiler and dub. The default configuration opens SDL3 at startup, so
it wants the SDL3 and SDL3_ttf shared libraries installed (`libsdl3-0` and
`libsdl3-ttf-0` on Debian/Ubuntu, `SDL3.dll` and `SDL3_ttf.dll` beside the
executable on Windows).

```
dub build
```

The `static` configuration links SDL3 in instead, for a binary that runs with
nothing installed, and needs the libraries built first:

```
./build-sdl3-debian.sh      # installs libSDL3.a / libSDL3_ttf.a into ~/.local
dub build -c static
```

Windows uses `build-sdl3.ps1`, which installs into `./install` instead.

## Hacking

`source/README.md` has the module map and the cross-module notes.

## License

Proprietary. Copyright (c) 2026, dd86k <dd@dax.moe>.
