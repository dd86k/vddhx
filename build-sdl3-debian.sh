#!/usr/bin/env bash
set -euo pipefail

# For Debian/Ubuntu
# X11: Needs libxtst-dev

PREFIX="${1:-$HOME/.local}"
SDL_TAG="release-3.4.12"        # pin a real SDL3 tag, not main
SDL_TTF_TAG="release-3.2.2"     # matches the SDL_TTF_3_2_2 version in dub.sdl

# --- 1. build-time deps (only prompts sudo once; harmless to re-run) ---
# SDL_ttf links the system freetype+harfbuzz (vendored static builds those but
# never install their archives, so a static link cannot find them). The
# fonts-noto-* packages are the runtime side: the app locates faces by probing
# /usr/share/fonts/**/noto (see source/render.d).
# The guard checks libharfbuzz-dev too so an existing checkout still picks up
# the fonts/freetype/harfbuzz packages on a re-run (dpkg -s fails if ANY is missing).
if ! dpkg -s libwayland-dev libharfbuzz-dev >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y build-essential cmake ninja-build git \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev \
    libxfixes-dev libxss-dev libwayland-dev wayland-protocols \
    libxkbcommon-dev libegl1-mesa-dev libgles2-mesa-dev \
    libpulse-dev libasound2-dev libdbus-1-dev \
    libfreetype-dev libharfbuzz-dev \
    fonts-noto-core fonts-noto-mono fonts-noto-cjk
fi

# --- clone + build static release, then install ---
[ -d SDL ] || git clone --depth 1 --branch "$SDL_TAG" \
  https://github.com/libsdl-org/SDL.git SDL

# Clean build because settings might change or container version gets confused
[ -d SDL/build ] && rm -rf SDL/build

cmake -S SDL -B SDL/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DSDL_SHARED=OFF \
  -DSDL_STATIC=ON \
  -DSDL_TEST=OFF

cmake --build SDL/build
cmake --install SDL/build

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# --- SDL_ttf: static libSDL3_ttf.a against the system freetype+harfbuzz ---
# CMAKE_PREFIX_PATH points it at the SDL3 we just installed. VENDORED=OFF makes
# it link the distro freetype/harfbuzz (found via pkg-config), so the final
# static link resolves against those shared libs -- ubiquitous on any desktop.
[ -d SDL_ttf ] || git clone --depth 1 --branch "$SDL_TTF_TAG" \
  https://github.com/libsdl-org/SDL_ttf.git SDL_ttf

[ -d SDL_ttf/build ] && rm -rf SDL_ttf/build

cmake -S SDL_ttf -B SDL_ttf/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF \
  -DSDLTTF_VENDORED=OFF \
  -DSDLTTF_HARFBUZZ=ON \
  -DSDLTTF_SAMPLES=OFF

cmake --build SDL_ttf/build
cmake --install SDL_ttf/build

echo
echo "== sdl3 static link line =="
pkg-config --static --cflags --libs sdl3
echo "== sdl3_ttf static link line (check dub.sdl posix libs match) =="
pkg-config --static --cflags --libs sdl3_ttf

echo
echo "Installed to $PREFIX"
echo "  static lib : $PREFIX/lib/libSDL3.a, libSDL3_ttf.a (freetype/harfbuzz are system libs)"
echo "  headers    : $PREFIX/include/SDL3/, $PREFIX/include/SDL3_ttf/"
echo "  pkg-config : $PREFIX/lib/pkgconfig/sdl3.pc, sdl3_ttf.pc"
echo "  cmake cfg  : $PREFIX/lib/cmake/SDL3/, SDL3_ttf/"
