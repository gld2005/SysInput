param(
    [string]$InnoCompiler = "",
    [string]$ZigCompiler = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$installerScript = Join-Path $projectRoot "installer\SysInput.iss"
$distDirectory = Join-Path $projectRoot "dist"

if ([string]::IsNullOrWhiteSpace($ZigCompiler)) {
    $pathZig = Get-Command zig.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
    $zigCandidates = @(
        (Join-Path $projectRoot ".tools\zig-windows-x86_64-0.14.0\zig.exe"),
        $pathZig
    )
    $ZigCompiler = $zigCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($ZigCompiler) -or -not (Test-Path -LiteralPath $ZigCompiler)) {
    throw "Zig 0.14.0 was not found. Pass -ZigCompiler with the zig.exe path."
}

if ([string]::IsNullOrWhiteSpace($InnoCompiler)) {
    $pathInno = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
    $candidates = @(
        (Join-Path $projectRoot ".tools\inno-setup\ISCC.exe"),
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe",
        $pathInno
    )
    $InnoCompiler = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($InnoCompiler) -or -not (Test-Path -LiteralPath $InnoCompiler)) {
    throw "Inno Setup 6 compiler was not found. Pass -InnoCompiler with the ISCC.exe path."
}

$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $projectRoot ".zig-global-cache"
Push-Location $projectRoot
try {
    & $ZigCompiler build test -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) { throw "Automated tests failed." }

    & $ZigCompiler build -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) { throw "ReleaseFast build failed." }

    New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
    & $InnoCompiler $installerScript
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed." }

    $installer = Get-ChildItem -LiteralPath $distDirectory -Filter "SysInput-Setup-0.2.0-rc1.exe" | Select-Object -First 1
    if ($null -eq $installer) { throw "The expected RC1 installer was not generated." }

    $hash = Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256
    $checksumPath = "$($installer.FullName).sha256"
    Set-Content -LiteralPath $checksumPath -Encoding ascii -Value "$($hash.Hash.ToLowerInvariant())  $($installer.Name)"

    [pscustomobject]@{
        Installer = $installer.FullName
        SizeMiB = [math]::Round($installer.Length / 1MB, 2)
        SHA256 = $hash.Hash.ToLowerInvariant()
        Checksum = $checksumPath
    }
}
finally {
    Pop-Location
}
