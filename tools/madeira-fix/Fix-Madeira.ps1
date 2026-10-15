<#
.SYNOPSIS
  Windows front end for madeira-fix.sh (runs it in WSL Ubuntu).

.EXAMPLE
  .\Fix-Madeira.ps1 -Version 0.1.3
  .\Fix-Madeira.ps1 -Ipa C:\Users\me\Downloads\Madeira-0.1.4.ipa -Out C:\Users\me\Madeira-0.1.4-fixed.ipa
  .\Fix-Madeira.ps1 -Version 0.1.4 -Modules "tbs dcomp"

One-time WSL setup (an administrator prompt):
  wsl -d Ubuntu -u root -- apt-get install -y git curl python3 make gcc bison flex xz-utils
#>
param(
    [string]$Version,
    [string]$Ipa,
    [string]$Out,
    [string]$Modules = "tbs",
    [string]$VcRuntime,
    [string]$Distro = "Ubuntu",
    [string]$Work,
    [switch]$NoDock,
    [switch]$Check
)
$ErrorActionPreference = "Stop"
if (-not $Version -and -not $Ipa) { throw "Give -Version 0.1.3 or -Ipa path\to\Madeira.ipa" }

function ToWsl([string]$p) { (wsl -d $Distro -- wslpath -a ($p -replace '\\', '/')).Trim() }

$script = ToWsl (Join-Path $PSScriptRoot "madeira-fix.sh")
$fixArgs = @()
if ($Version) { $fixArgs += @("--version", $Version) }
if ($Ipa) { $fixArgs += @("--ipa", (ToWsl (Resolve-Path $Ipa).Path)) }
if (-not $Out) { $Out = Join-Path (Get-Location).Path ("Madeira-" + $(if ($Version) { $Version } else { "custom" }) + "-fixed.ipa") }
$fixArgs += @("--out", (ToWsl $Out), "--modules", $Modules)
if ($VcRuntime) { $fixArgs += @("--vcruntime", (ToWsl (Resolve-Path $VcRuntime).Path)) }
if ($Work) { $fixArgs += @("--work", $Work) }
if ($NoDock) { $fixArgs += "--no-dock" }
if ($Check) { $fixArgs += "--check" }

# WSL appends the Windows PATH; a Windows compiler or library directory on it can
# leak into the Linux build. Use a clean one.
wsl -d $Distro -- env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash $script @fixArgs
if ($LASTEXITCODE -ne 0) { throw "madeira-fix failed ($LASTEXITCODE)" }
Write-Host "`nWrote $Out"
