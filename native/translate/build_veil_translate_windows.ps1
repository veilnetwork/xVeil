# Build veil_translate.dll for Windows x64 and prove it translates.
#
#   native/translate/build_veil_translate_windows.ps1 [-Dest <dir>]
#
# One file, like every other platform: CTranslate2 and SentencePiece are folded
# in statically, because a translation feature that ships as an engine plus a
# tokeniser plus their transitive halves is three chances to arrive incomplete.
#
# Run from a Developer PowerShell for VS (cl.exe and link.exe on PATH).
#
# Prereqs, both built where this expects them:
#   CTranslate2:   $CT2_SRC\build-windows-static\Release\ctranslate2.lib
#     cmake -DBUILD_SHARED_LIBS=OFF -DWITH_MKL=OFF -DWITH_RUY=ON `
#           -DOPENMP_RUNTIME=NONE -DBUILD_CLI=OFF -DBUILD_TESTS=OFF
#   SentencePiece: $SPM_SRC\build-windows-x64\src\Release\sentencepiece.lib
#     cmake -DSPM_ENABLE_SHARED=OFF -DSPM_BUILD_TEST=OFF -DSPM_ENABLE_TCMALLOC=OFF
#
# The default destination is native\translate\windows, which is exactly where
# builder.py's staging step looks. That step was written before this script
# existed and stays inert until this produces something -- the "built, verified
# and unreachable" failure that cost this repository four defects in one week
# on the other platforms.
[CmdletBinding()]
param(
  [string]$Dest = (Join-Path $PSScriptRoot 'windows'),
  [string]$Ct2Src = $env:CT2_SRC,
  [string]$SpmSrc = $env:SPM_SRC,
  [string]$TestModel = $env:VEIL_TRANSLATE_TEST_MODEL
)

$ErrorActionPreference = 'Stop'
if (-not $Ct2Src) { $Ct2Src = Join-Path $HOME 'CTranslate2' }
if (-not $SpmSrc) { $SpmSrc = Join-Path $HOME 'sentencepiece' }

$ct2Build = if ($env:CT2_BUILD) { $env:CT2_BUILD } else { Join-Path $Ct2Src 'build-windows-static' }
$spmBuild = if ($env:SPM_BUILD) { $env:SPM_BUILD } else { Join-Path $SpmSrc 'build-windows-x64' }

# A developer who has configured a multi-config generator has BOTH Debug and
# Release next to each other, and a recursive search returns both. Two hazards,
# neither of which announces itself: `Select-Object -First 1` takes whichever
# the filesystem enumerates first -- alphabetically that is Debug -- and the
# dependency sweep below would hand link.exe one archive of each configuration,
# built against a different CRT than the /MD this compiles with.
$notDebug = { $_.FullName -notmatch '[\\/]Debug[\\/]' }

$ct2Lib = Get-ChildItem -Path $ct2Build -Filter 'ctranslate2.lib' -Recurse -File -ErrorAction SilentlyContinue | Where-Object $notDebug | Select-Object -First 1
if (-not $ct2Lib) { throw "no ctranslate2.lib under $ct2Build - build CTranslate2 static first" }
$spmLib = Get-ChildItem -Path $spmBuild -Filter 'sentencepiece.lib' -Recurse -File -ErrorAction SilentlyContinue | Where-Object $notDebug | Select-Object -First 1
if (-not $spmLib) { throw "no sentencepiece.lib under $spmBuild - build SentencePiece static first" }

$abslInc = Join-Path $spmBuild '_deps\abseil-cpp-src'
if (-not (Test-Path $abslInc)) { throw "no abseil sources at $abslInc - SentencePiece fetches them at configure time" }

$version = (Select-String -Path (Join-Path $Ct2Src 'python\ctranslate2\version.py') `
  -Pattern '^__version__ = "(.*)"').Matches.Groups[1].Value
if (-not $version) { $version = 'unknown' }
Write-Host "==> ctranslate2 $version"

# Everything both trees produced, minus the trainer (we never train) and protoc
# (a compiler, not a runtime). protobuf-lite is EXCLUDED for the reason the iOS
# script documents at length: it duplicates protobuf.lib's objects, and shipping
# two copies of the same object to a linker is not something to rely on the
# linker to sort out.
$deps = @()
$deps += Get-ChildItem -Path $ct2Build -Filter '*.lib' -Recurse -File | Where-Object $notDebug |
  Where-Object { $_.Name -ne 'ctranslate2.lib' } | ForEach-Object { $_.FullName }
$deps += Get-ChildItem -Path $spmBuild -Filter '*.lib' -Recurse -File | Where-Object $notDebug |
  Where-Object { $_.Name -notmatch 'train' -and $_.Name -ne 'protoc.lib' -and
                 $_.Name -ne 'libprotoc.lib' -and $_.Name -ne 'protobuf-lite.lib' } |
  ForEach-Object { $_.FullName }
if ($deps.Count -eq 0) { throw "no static libraries under $ct2Build or $spmBuild" }

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP ("veiltr-" + [guid]::NewGuid()))

# The export list, DERIVED from the header rather than typed here.
#
# A hand-written list goes stale the moment an entry point is added, and it is
# silent in the worst direction: the symbol exists in the object, the .def does
# not name it, and the app fails at GetProcAddress on a DLL that built and
# linked cleanly. I wrote that list by hand once for Linux and put a
# veil_translate_batch in it that does not exist.
#
# The .def is also what keeps this DLL from exporting all of protobuf, abseil
# and the engine into a process that already loads veilclient_ffi and
# veil_media. On Windows a .def file is the whole export table: name it or it
# is not exported.
$header = Join-Path $PSScriptRoot 'veil_translate.h'
$wanted = Select-String -Path $header -Pattern 'veil_translate[a-z_]*\(' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Value.TrimEnd('(') } |
  Sort-Object -Unique
# A floor, not a non-empty test. Every check below is keyed on this list, so a
# regex that stops matching does not fail -- it shrinks the .def, shrinks what
# the DLL exports, and the set comparison agrees with itself on the remainder.
# The header declares six; five is the alarm.
if ($wanted.Count -lt 5) {
  throw "found only $($wanted.Count) entry points in $header - discovery is broken, not the header"
}
$defPath = Join-Path $tmp 'veil_translate.def'
@('EXPORTS') + $wanted | Set-Content -Path $defPath -Encoding ASCII

$obj = Join-Path $tmp 'veil_translate.obj'
& cl.exe /nologo /std:c++17 /O2 /EHsc /MD /c `
  "/I$PSScriptRoot" "/I$(Join-Path $Ct2Src 'include')" `
  "/I$(Join-Path $SpmSrc 'src')" "/I$SpmSrc" "/I$abslInc" `
  "/DVEIL_TRANSLATE_CT2_VERSION=\`"$version\`"" `
  "/Fo$obj" (Join-Path $PSScriptRoot 'veil_translate.cc')
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

$dll = Join-Path $Dest 'veil_translate.dll'
& link.exe /nologo /DLL "/OUT:$dll" "/DEF:$defPath" `
  "/WHOLEARCHIVE:$($ct2Lib.FullName)" $obj $deps `
  Advapi32.lib Ws2_32.lib Shlwapi.lib
if ($LASTEXITCODE -ne 0) { throw "link failed" }

Write-Host "==> $dll"
Get-Item $dll | Format-List Length, LastWriteTime | Out-String | Write-Host

# What the app can actually reach. dumpbin /EXPORTS reads the export table --
# the question GetProcAddress answers. `nm`-style symbol listings would report a
# symbol that is defined but not exported, which is a green check for a DLL the
# app cannot call into; the mac-side symbol gate learned that the same week.
#
# Read the ROWS of that table -- ordinal, hint, RVA, name -- and take the name
# column, the way the Linux sibling takes nm's last field. A pattern run over
# the whole of dumpbin's output instead matches dumpbin's own prose: it prints
# "Dump of file ...\veil_translate.dll" and "the following exports for
# veil_translate.dll" before the table, so the string veil_translate is present
# even when the export table is EMPTY. That made this gate certify a DLL whose
# primary entry point -- veil_translate itself, the call that translates -- was
# not exported at all, and report "exports 1" for a library exporting nothing.
$dumped = & dumpbin.exe /EXPORTS $dll
$exports = $dumped |
  Select-String -Pattern '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)' |
  ForEach-Object { $_.Matches[0].Groups[1].Value } |
  Where-Object { $_ -match '^veil_translate[a-z_]*$' } | Sort-Object -Unique

# Set EQUALITY, not a count: a count passes when a symbol the app looks up is
# missing and an unrelated one took its place, which is the shape a rename
# produces.
$missing = $wanted | Where-Object { $_ -notin $exports }
$extra = $exports | Where-Object { $_ -notin $wanted }
Write-Host "exports $($exports.Count) veil_translate_* entry points"
if ($missing) { throw "::error::the DLL does not export: $($missing -join ', ')" }
if ($extra) { throw "::error::the DLL exports names the header does not declare: $($extra -join ', ')" }

# And what it must NOT reach. A leaked protobuf or abseil export is the whole
# reason the .def exists, so the check is here rather than in a comment saying
# it was considered.
$leaked = $dumped |
  Select-String -Pattern '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)' |
  ForEach-Object { $_.Matches[0].Groups[1].Value } |
  Where-Object { $_ -match '(google|absl|sentencepiece|ctranslate2)' } |
  Measure-Object | Select-Object -ExpandProperty Count
if ($leaked -ne 0) {
  throw "::error::$leaked protobuf/abseil/engine names are exported - they can collide with another library in the same process"
}

if ($TestModel -and (Test-Path $TestModel)) {
  Write-Host "==> selftest against $TestModel"
  $exe = Join-Path $tmp 'selftest.exe'
  & cl.exe /nologo "/I$PSScriptRoot" (Join-Path $PSScriptRoot 'selftest.c') `
    "/Fe$exe" /link (Join-Path $Dest 'veil_translate.lib')
  if ($LASTEXITCODE -ne 0) { throw "selftest build failed" }
  Copy-Item $dll (Split-Path $exe) -Force
  & $exe $TestModel
  if ($LASTEXITCODE -ne 0) { throw "selftest FAILED" }
} else {
  Write-Host "==> selftest NOT RUN: no model at '$TestModel'"
  Write-Host "    set VEIL_TRANSLATE_TEST_MODEL to a CTranslate2 model directory"
  Write-Host "    containing source.spm and target.spm. The library is built but"
  Write-Host "    nothing has checked that it translates."
}
