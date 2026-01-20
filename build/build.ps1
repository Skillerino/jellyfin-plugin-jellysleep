#!/usr/bin/env pwsh
<#
Build script for Jellyfin plugin (PowerShell port of the provided Bash script)

Options:
  -c, --configuration CONF  Build configuration (Debug|Release) [default: Release]
  --clean                   Clean before build
  -p, --package             Create plugin package (checks expected package output)
  -v, --version VERSION     Set version before build (calls update-version script)
  -h, --help                Show this help
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Apply $ErrorActionPreference to native commands when available (PowerShell 7+)
if (Get-Variable -Name 'PSNativeCommandUseErrorActionPreference' -Scope Global -ErrorAction SilentlyContinue) {
    $global:PSNativeCommandUseErrorActionPreference = $true
}

# --- Configuration (mirrors Bash script) ---
$PluginName   = 'Jellyfin.Plugin.Jellysleep'
$ScriptDir    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SolutionFile = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\$PluginName.sln"))
$BuildDir     = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\bin"))

# --- Logging ---
function Log-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Green }
function Log-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Log-Error([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Show-Help {
    Write-Host "Usage: $(Split-Path -Leaf $MyInvocation.MyCommand.Path) [OPTIONS]"
    Write-Host "Options:"
    Write-Host "  -c, --configuration CONF  Build configuration (Debug|Release) [default: Release]"
    Write-Host "  --clean                   Clean before build"
    Write-Host "  -p, --package             Create plugin package"
    Write-Host "  -v, --version VERSION     Set version before build"
    Write-Host "  -h, --help                Show this help"
}

function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$false)][string[]]$Arguments = @()
    )
    & $FilePath @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "Command failed ($code): $FilePath $($Arguments -join ' ')"
    }
}

function Format-Bytes([long]$Bytes) {
    $units = @('B','KB','MB','GB','TB','PB')
    [double]$size = $Bytes
    $unit = 0
    while ($size -ge 1024 -and $unit -lt ($units.Count - 1)) {
        $size /= 1024
        $unit++
    }
    if ($unit -eq 0) { return "$Bytes $($units[$unit])" }
    return ("{0:N1} {1}" -f $size, $units[$unit])
}

function Get-PluginVersionFromCsproj([string]$CsprojPath) {
    if (-not (Test-Path -LiteralPath $CsprojPath)) {
        throw "Project file not found: $CsprojPath"
    }

    $raw = Get-Content -LiteralPath $CsprojPath -Raw
    try {
        [xml]$xml = $raw
        $node = $xml.SelectSingleNode("//*[local-name()='PluginVersion']")
        if ($null -ne $node -and -not [string]::IsNullOrWhiteSpace($node.InnerText)) {
            return $node.InnerText.Trim()
        }
    } catch {
        # fall back to regex below
    }

    $m = [regex]::Match($raw, '<PluginVersion>\s*([^<]+)\s*</PluginVersion>')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }

    throw "Could not determine <PluginVersion> from: $CsprojPath"
}

# --- Parse command line arguments (Bash-compatible flags) ---
$Configuration = 'Release'
$Clean   = $false
$Package = $false
$Version = $null
$ShowHelpFlag = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    switch ($a) {
        '-c' { $i++; if ($i -ge $args.Count) { throw "Missing value for -c/--configuration" }; $Configuration = [string]$args[$i] }
        '--configuration' { $i++; if ($i -ge $args.Count) { throw "Missing value for -c/--configuration" }; $Configuration = [string]$args[$i] }
        '--clean' { $Clean = $true }
        '-p' { $Package = $true }
        '--package' { $Package = $true }
        '-v' { $i++; if ($i -ge $args.Count) { throw "Missing value for -v/--version" }; $Version = [string]$args[$i] }
        '--version' { $i++; if ($i -ge $args.Count) { throw "Missing value for -v/--version" }; $Version = [string]$args[$i] }
        '-h' { $ShowHelpFlag = $true }
        '--help' { $ShowHelpFlag = $true }
        default {
            Log-Error "Unknown option: $a"
            Show-Help
            exit 1
        }
    }
}

if ($ShowHelpFlag) {
    Show-Help
    exit 0
}

# --- Move to script directory (mirrors Bash) ---
Set-Location -LiteralPath $ScriptDir

# --- Preconditions ---
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet not found in PATH."
}
if (-not (Test-Path -LiteralPath $SolutionFile)) {
    throw "Solution file not found: $SolutionFile"
}

Log-Info "Building Jellyfin Plugin: $PluginName"
Log-Info "Configuration: $Configuration"

# --- Update version if provided ---
if (-not [string]::IsNullOrWhiteSpace($Version)) {
    Log-Info "Updating version to: $Version"

    $updatePs1 = Join-Path $ScriptDir 'update-version.ps1'
    $updateSh  = Join-Path $ScriptDir 'update-version.sh'

    if (Test-Path -LiteralPath $updatePs1) {
        & $updatePs1 $Version
    }
    elseif (Test-Path -LiteralPath $updateSh) {
        if (Get-Command bash -ErrorAction SilentlyContinue) {
            Invoke-Native -FilePath 'bash' -Arguments @($updateSh, $Version)
        }
        elseif (Get-Command sh -ErrorAction SilentlyContinue) {
            Invoke-Native -FilePath 'sh' -Arguments @($updateSh, $Version)
        }
        else {
            throw "Found update-version.sh but neither bash nor sh is available to execute it."
        }
    }
    else {
        throw "No update-version script found (expected update-version.ps1 or update-version.sh in $ScriptDir)."
    }
}

# --- Clean if requested ---
if ($Clean) {
    Log-Info "Cleaning previous builds..."
    Invoke-Native -FilePath 'dotnet' -Arguments @('clean', $SolutionFile, '--configuration', $Configuration, '--verbosity', 'minimal')

    if (Test-Path -LiteralPath $BuildDir) {
        Remove-Item -LiteralPath $BuildDir -Recurse -Force
    }
}

# --- Restore packages ---
Log-Info "Restoring NuGet packages..."
Invoke-Native -FilePath 'dotnet' -Arguments @('restore', $SolutionFile, '--verbosity', 'minimal')

# --- Build ---
Log-Info "Building solution..."
Invoke-Native -FilePath 'dotnet' -Arguments @(
    'build', $SolutionFile,
    '--configuration', $Configuration,
    '--no-restore',
    '--verbosity', 'minimal',
    '/property:GenerateFullPaths=true',
    '/consoleloggerparameters:NoSummary'
)

# --- Publish ---
Log-Info "Publishing plugin..."
Invoke-Native -FilePath 'dotnet' -Arguments @(
    'publish', $SolutionFile,
    '--configuration', $Configuration,
    '--no-build',
    '--verbosity', 'minimal',
    '/property:GenerateFullPaths=true',
    '/consoleloggerparameters:NoSummary'
)

# --- Create package if requested (mirrors Bash: only checks expected output) ---
if ($Package) {
    Log-Info "Creating plugin package..."

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $csproj = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\$PluginName\$PluginName.csproj"))
        $Version = Get-PluginVersionFromCsproj -CsprojPath $csproj
    }

    $PackageName = "jellyfin-plugin-jellysleep-$Version.zip"
    $PackagePath = Join-Path $BuildDir $PackageName

    Log-Info "Package will be created by MSBuild target..."

    if (Test-Path -LiteralPath $PackagePath) {
        Log-Info "Package created: $PackagePath"

        $item = Get-Item -LiteralPath $PackagePath
        $sizeHuman = Format-Bytes -Bytes $item.Length
        $hash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash

        Log-Info "Package size: $sizeHuman"
        Log-Info "SHA256: $hash"

        Log-Info "Package contents:"
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
            $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
            try {
                $dlls = $zip.Entries |
                    Where-Object { $_.FullName -match '\.dll$' } |
                    ForEach-Object { "  - $($_.FullName)" }

                if ($dlls.Count -gt 0) { $dlls | ForEach-Object { Write-Host $_ } }
                else { Write-Host "  (no .dll entries found)" }
            }
            finally {
                $zip.Dispose()
            }
        }
        catch {
            Log-Info "  (could not read zip contents: $($_.Exception.Message))"
        }
    }
    else {
        Log-Warn "Package not found at expected location: $PackagePath"
        Log-Info "Check if the package is created elsewhere by your build targets."
    }
}

Log-Info "Build completed successfully!"
