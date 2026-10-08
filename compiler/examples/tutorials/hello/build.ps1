# build.ps1 — one program, six platforms, from Windows.
#
#   .\build.ps1                 builds every platform into build\<platform>\
#   .\build.ps1 windows         builds one (mac, linux, windows, web, ios, android)
#   .\build.ps1 windows -Run    builds it and runs it (windows and web run here)
#   .\build.ps1 clean           removes build\
#
# Every knob is a parameter, so it can be set on the command line:
#
#   .\build.ps1 windows -Opt -O0 -Flags -g               a debuggable Windows build
#   .\build.ps1 -Xcc C:\xcc\xcc-win64-0.74\bin\xcc.exe   a particular compiler
#   .\build.ps1 ios -Ios ios                             the iOS device, not the simulator
#
# If PowerShell refuses to run scripts: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

param(
    # The platforms to build: any of mac linux windows web ios android, all, clean.
    [string[]] $Targets = @('all'),
    # The compiler: xcc on the PATH, or a full path to one.
    [string] $Xcc   = 'xcc',
    # Optimisation: -O0 (the fastest build) to -O3 (the fastest code).
    [string] $Opt   = '-O3',
    # Anything else: -g for debug information, -static, -q, -Wanalyze …
    [string] $Flags = '',
    # ios-sim (the simulator) or ios (a device, which needs signing).
    [string] $Ios   = 'ios-sim',
    # Run the program after building it (windows and web run on this machine).
    [switch] $Run
)

$ErrorActionPreference = 'Stop'

# The program. The outputs are build\<platform>\hello, hello.exe, hello.wasm …
$Name  = 'hello'
$Src   = 'hello.xc'
$Build = 'build'

# One entry per platform: the -A target, the output file, and how to run it.
$Platforms = @{
    mac     = @{ Arch = 'arm64';   Out = "$Name";      Run = $null }
    linux   = @{ Arch = 'x86_64';  Out = "$Name";      Run = $null }
    windows = @{ Arch = 'win64';   Out = "$Name.exe";  Run = { & $args[0] } }
    web     = @{ Arch = 'wasm32';  Out = "$Name.wasm"; Run = { node ($args[0] -replace '\.wasm$', '.js') } }
    ios     = @{ Arch = $Ios;      Out = "$Name";      Run = $null }
    android = @{ Arch = 'android'; Out = "$Name.apk";  Run = $null; Extra = '--emit-apk' }
}

function Build-Platform([string] $Platform) {
    $p   = $Platforms[$Platform]
    $dir = Join-Path $Build $Platform
    New-Item -ItemType Directory -Force $dir | Out-Null
    $out = Join-Path $dir $p.Out
    # The same command for every platform: -A picks the target. $Flags may
    # hold several flags ("-g -Wanalyze"), so it is split into words.
    $cmd = @($Xcc, '-A', $p.Arch) + @(@($p.Extra, $Opt) + ($Flags -split ' ') | Where-Object { $_ }) + @('-o', $out, $Src)
    Write-Host ($cmd -join ' ')
    & $cmd[0] $cmd[1..($cmd.Count - 1)]
    if ($LASTEXITCODE -ne 0) { throw "${Platform}: xcc failed" }
    if ($Run) {
        if ($p.Run) { & $p.Run $out }
        else { Write-Host "${Platform}: built $out; run it on that platform (see the Makefile's run-$Platform)" }
    }
}

foreach ($t in $Targets) {
    switch ($t) {
        'all'   { foreach ($k in 'mac', 'linux', 'windows', 'web', 'ios', 'android') { Build-Platform $k } }
        'clean' { if (Test-Path $Build) { Remove-Item -Recurse -Force $Build } }
        default {
            if (-not $Platforms.ContainsKey($t)) { throw "unknown target '$t': mac linux windows web ios android all clean" }
            Build-Platform $t
        }
    }
}
