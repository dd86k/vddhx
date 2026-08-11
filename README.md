# vddhx

Visual DDHX: a graphical port of the [ddhx](https://github.com/dd86k/ddhx) hex editor on
SDL3 and [ddui](https://github.com/dd86k/ddui), while using the same robust document core as ddhx.

Tabs and splits, byte-class colouring, a minimap, ddhx's find and goto syntax,
bookmarks, byte-for-byte compare, and an omnibar over the lot.

Status: 0.1.0, in development.

## Building

Needs a D compiler, dub, and a static SDL3 + SDL3_ttf.

```
./build-sdl3-debian.sh      # installs libSDL3.a / libSDL3_ttf.a into ~/.local
dub build
```

Windows uses `build-sdl3.ps1`, which installs into `./install` instead.

## Hacking

`source/README.md` has the module map and the cross-module notes.

## License

Proprietary. Copyright (c) 2026, dd86k <dd@dax.moe>.
