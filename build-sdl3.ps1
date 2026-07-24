#Requires -Version 5.1
<#
.SYNOPSIS
    Windows equivalent of build_sdl3.sh: builds and installs a static SDL3.

.DESCRIPTION
    Builds SDL3 with MSVC (cl) + Ninja, because DMD/LDC target the MSVC ABI on
    64-bit Windows. Do NOT build this with the mingw64 gcc that is on PATH --
    the resulting archive uses a different CRT and will not link into a D binary.

.PARAMETER Prefix
    Install prefix. Defaults to <repo>/install.

.PARAMETER SdlTag
    SDL3 git tag to build.

.PARAMETER NoClean
    Keep an existing SDL/build directory instead of removing it.

.PARAMETER DynamicCrt
    Build SDL against the dynamic UCRT (/MD) instead of the static one (/MT).
    Only use this if you also build the D side with -mscrtlib=msvcrt; by default
    DMD/LDC link the static CRT, and a mismatch produces unresolved __imp_*
    symbols plus LNK4098.
#>
[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path $PSScriptRoot 'install'),
    [string]$SdlTag = 'release-3.4.12',
    [string]$SdlTtfTag = 'release-3.2.2',
    [switch]$NoClean,
    [switch]$DynamicCrt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 wraps anything a native exe writes to stderr in an
# ErrorRecord, which $ErrorActionPreference='Stop' then treats as fatal -- so a
# mere cmake warning would abort the build. Run native tools with that relaxed
# and judge success by exit code, which is the only reliable signal.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Args
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Args[0] @($Args[1..($Args.Count - 1)])
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

$SdlDir      = Join-Path $PSScriptRoot 'SDL'
$BuildDir    = Join-Path $SdlDir 'build'
$SdlTtfDir   = Join-Path $PSScriptRoot 'SDL_ttf'
$TtfBuildDir = Join-Path $SdlTtfDir 'build'

# --- 1. locate MSVC and import its environment -------------------------------
# There is no apt step on Windows; the Win32/D3D/WASAPI backends SDL needs are
# all in the Windows SDK, which comes with the MSVC install.

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw @"
vswhere.exe not found -- no Visual Studio / Build Tools install detected.

Install the C++ build tools (free, no full IDE required):
    winget install --id Microsoft.VisualStudio.2022.BuildTools ``
        --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

The mingw64 gcc already on PATH is NOT a substitute: DMD/LDC produce
MSVC-ABI objects on win64 and cannot link a gcc-built libSDL3.a.
"@
}

$vsRoot = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsRoot) {
    throw "Visual Studio found, but the 'Desktop development with C++' workload (VC.Tools.x86.x64) is not installed."
}

$vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vsRoot" }

Write-Host "Importing MSVC environment from $vcvars" -ForegroundColor Cyan
# cmd exits with the env of the batch file; harvest it back into this session so
# cmake sees cl.exe, the Windows SDK headers, and the right LIB/INCLUDE paths.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$envDump = & "$env:ComSpec" /c "call `"$vcvars`" >nul 2>&1 && set"
$ErrorActionPreference = $prevEap
if ($LASTEXITCODE -ne 0) { throw "vcvars64.bat failed with exit code $LASTEXITCODE" }
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
    }
}

# vcvars prepends the MSVC toolchain to PATH, but mingw64 is still on it and
# ships its own cmake/ninja. Pin the compiler so CMake cannot pick up gcc.
$env:CC  = 'cl'
$env:CXX = 'cl'

foreach ($tool in 'cl', 'cmake', 'ninja', 'git') {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $found) { throw "Required tool '$tool' not found on PATH." }
    Write-Host ("  {0,-6} {1}" -f $tool, $found.Source)
}

# --- 2. clone + build static release, then install ---------------------------
if (-not (Test-Path $SdlDir)) {
    Write-Host "Cloning SDL $SdlTag" -ForegroundColor Cyan
    Invoke-Native 'git clone' git clone --depth 1 --branch $SdlTag `
        https://github.com/libsdl-org/SDL.git $SdlDir
} else {
    Write-Host "Reusing existing checkout at $SdlDir" -ForegroundColor Yellow
    # Purely informational: a network-share checkout can trip git's
    # "dubious ownership" guard, which must not abort the build.
    try {
        $desc = & git -C $SdlDir describe --tags --always
        if ($LASTEXITCODE -eq 0 -and $desc) { Write-Host "  currently at: $desc" }
    } catch {
        Write-Host "  (could not determine checked-out ref)"
    }
}

# Clean build because settings might change or the cache gets confused
if ((Test-Path $BuildDir) -and (-not $NoClean)) {
    Write-Host "Removing stale $BuildDir" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $BuildDir
}

# DMD/LDC link the static CRT (libcmt) by default on win64. SDL defaults to the
# dynamic UCRT, and mixing the two yields unresolved __imp_atof/__imp_round/...
# at link time, so match the D toolchain unless explicitly told otherwise.
# NOTE: this is CMAKE_MSVC_RUNTIME_LIBRARY, not SDL_FORCE_STATIC_VCRT -- the
# latter is an SDL2 option that SDL3 ignores silently.
if ($DynamicCrt) {
    $crt = 'MultiThreadedDLL'
    Write-Host "CRT: dynamic (/MD) -- build the D side with -mscrtlib=msvcrt" -ForegroundColor Yellow
} else {
    $crt = 'MultiThreaded'
    Write-Host "CRT: static (/MT), matching the DMD/LDC default" -ForegroundColor Cyan
}

Invoke-Native 'cmake configure' cmake -S $SdlDir -B $BuildDir -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_INSTALL_PREFIX="$Prefix" `
    -DSDL_SHARED=OFF `
    -DSDL_STATIC=ON `
    -DSDL_TESTS=OFF `
    -DSDL_TEST_LIBRARY=OFF `
    -DCMAKE_MSVC_RUNTIME_LIBRARY="$crt"

Invoke-Native 'cmake build'   cmake --build   $BuildDir
Invoke-Native 'cmake install' cmake --install $BuildDir

# --- 2b. SDL_ttf: vendored (freetype+harfbuzz bundled) static, same prefix ---
# Unlike the Debian script, Windows has no system freetype/harfbuzz to link, so
# it must vendor them. CMAKE_PREFIX_PATH points it at the SDL3 just installed;
# the static CRT must match what SDL and the D toolchain use, or the archives
# will not link together.
if (-not (Test-Path $SdlTtfDir)) {
    Write-Host "Cloning SDL_ttf $SdlTtfTag" -ForegroundColor Cyan
    Invoke-Native 'git clone' git clone --depth 1 --branch $SdlTtfTag `
        --recurse-submodules https://github.com/libsdl-org/SDL_ttf.git $SdlTtfDir
} else {
    Write-Host "Reusing existing checkout at $SdlTtfDir" -ForegroundColor Yellow
}

if ((Test-Path $TtfBuildDir) -and (-not $NoClean)) {
    Write-Host "Removing stale $TtfBuildDir" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $TtfBuildDir
}

Invoke-Native 'cmake configure (ttf)' cmake -S $SdlTtfDir -B $TtfBuildDir -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_INSTALL_PREFIX="$Prefix" `
    -DCMAKE_PREFIX_PATH="$Prefix" `
    -DBUILD_SHARED_LIBS=OFF `
    -DSDLTTF_VENDORED=ON `
    -DSDLTTF_HARFBUZZ=ON `
    -DSDLTTF_SAMPLES=OFF `
    -DCMAKE_MSVC_RUNTIME_LIBRARY="$crt"

Invoke-Native 'cmake build (ttf)'   cmake --build   $TtfBuildDir
Invoke-Native 'cmake install (ttf)' cmake --install $TtfBuildDir

# SDL_ttf installs libSDL3_ttf.a only: the vendored freetype/harfbuzz archives
# are built but left in the build tree, so the final static link cannot find
# them. Copy whatever static libs the build produced into the install lib dir.
$ttfLibDir = Join-Path $Prefix 'lib'
foreach ($name in 'freetype', 'harfbuzz') {
    $hit = Get-ChildItem -Path $TtfBuildDir -Recurse -File `
        -Include "$name.lib", "lib$name.a" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) {
        Copy-Item $hit.FullName -Destination $ttfLibDir -Force
        Write-Host "  vendored $($hit.Name) -> $ttfLibDir"
    } else {
        Write-Warning "Could not find a built $name archive under $TtfBuildDir; the link will fail."
    }
}

# --- 3. report what dub needs ------------------------------------------------
$LibDir     = Join-Path $Prefix 'lib'
$CMakeDir   = Join-Path $Prefix 'cmake'
$PcFile     = Join-Path $LibDir 'pkgconfig\sdl3.pc'
$StaticLib  = Join-Path $LibDir 'SDL3-static.lib'

# There is no pkg-config binary here, but SDL still installs sdl3.pc, and its
# Libs: line is the tidiest source for the transitive system libs -- the CMake
# targets file escapes each one as \$<LINK_ONLY:...> and needs unwrapping.
$allLibs = @()
if (Test-Path $PcFile) {
    $libsLine = Get-Content $PcFile | Where-Object { $_ -match '^Libs:' } | Select-Object -First 1
    if ($libsLine) {
        $allLibs = [regex]::Matches($libsLine, '-l(\S+)') |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique
    }
}
if (-not $allLibs) {
    Write-Warning "Could not read the lib list from $PcFile; falling back to SDL3-static only."
    $allLibs = @('SDL3-static')
}

Write-Host ""
Write-Host "Installed to $Prefix" -ForegroundColor Green
Write-Host "  static lib : $StaticLib (+ SDL3_ttf, vendored freetype/harfbuzz)"
Write-Host "  headers    : $(Join-Path $Prefix 'include\SDL3\')"
Write-Host "  pkg-config : $PcFile"
Write-Host "  cmake cfg  : $CMakeDir"

if (-not (Test-Path $StaticLib)) {
    Write-Warning "Expected $StaticLib but it is missing -- check the install output above."
}

# dub.sdl already carries a platform="windows" block with this lib list. Flag
# drift instead of reprinting it, so an SDL upgrade that adds or drops a system
# dependency does not turn into a confusing link error later.
$dubFile = Join-Path $PSScriptRoot 'dub.sdl'
$missing = @()
if (Test-Path $dubFile) {
    $dubText = Get-Content $dubFile -Raw
    $missing = $allLibs | Where-Object { $dubText -notmatch [regex]::Escape("`"$_`"") }
}

Write-Host ""
if (-not (Test-Path $dubFile)) {
    Write-Host "dub.sdl not found; link against:" -ForegroundColor Cyan
    Write-Host "  $($allLibs -join ' ')"
} elseif ($missing) {
    Write-Warning "dub.sdl is missing these libs SDL now needs: $($missing -join ' ')"
    Write-Host "Update the platform=`"windows`" libs line in dub.sdl." -ForegroundColor Yellow
} else {
    Write-Host "dub.sdl already links all $($allLibs.Count) required libs." -ForegroundColor Green
}
Write-Host ""
