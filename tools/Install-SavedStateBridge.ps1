<#
.SYNOPSIS
    Installs (or removes) AKForeverWeaponBuffs_SavedState, a companion addon that works around the
    WoW: Forever beta client writing SavedVariables on logout but never reading them back.

.DESCRIPTION
    A SavedVariables file is plain Lua ("AKForeverWeaponBuffsDB = { ... }"). The client refuses to
    load it as saved data, but happily runs it as addon code. So this creates

        Interface\AddOns\AKForeverWeaponBuffs_SavedState\
            AKForeverWeaponBuffs_SavedState.toc
            Before.lua
            SV\            <- directory junction to WTF\Account\<account>\SavedVariables
            After.lua

    whose .toc lists SV\AKForeverWeaponBuffs.lua. AKForeverWeaponBuffs declares it as an OptionalDep, so it
    runs first and AKForeverWeaponBuffs finds its saved table already in place.

    Nothing here is needed once Blizzard fixes the client: run with -Remove (or delete the
    folder - but see the warning in Remove-JunctionOnly before doing that by hand).

.EXAMPLE
    .\tools\Install-SavedStateBridge.ps1
    .\tools\Install-SavedStateBridge.ps1 -LegacyCharacterFolder '70\Purrdee-Bubson'
    .\tools\Install-SavedStateBridge.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$ClientPath = 'C:\Program Files (x86)\World of Warcraft\_classic_beta_',

    # Folder name under WTF\Account. Default: the account that already has a AKForeverWeaponBuffs.lua.
    [string]$Account,

    # One-time: also feed AKForeverWeaponBuffs 2.0.0's per-character file to the addon so it can adopt
    # it, e.g. '70\Purrdee-Bubson' (relative to the account folder).
    [string]$LegacyCharacterFolder,

    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$addonDir = Join-Path $ClientPath 'Interface\AddOns\AKForeverWeaponBuffs_SavedState'
$links = @{ SV = (Join-Path $addonDir 'SV'); SVChar = (Join-Path $addonDir 'SVChar') }

function Remove-JunctionOnly([string]$Path) {
    # WARNING: in Windows PowerShell 5.1, "Remove-Item -Recurse" on a junction deletes the
    # CONTENTS OF THE TARGET - here, every addon's saved settings. rmdir without /s removes
    # only the link itself.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -ne 'Junction') {
        throw "$Path exists but is not a junction - refusing to touch it."
    }
    cmd /c rmdir "`"$Path`"" | Out-Null
    if (Test-Path -LiteralPath $Path) { throw "could not remove junction $Path" }
}

function Remove-Bridge {
    foreach ($link in $links.Values) { Remove-JunctionOnly $link }
    if (Test-Path -LiteralPath $addonDir) {
        $reparse = Get-ChildItem -LiteralPath $addonDir -Force -Recurse |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
        if ($reparse) { throw "unexpected links left in ${addonDir}: $($reparse.FullName -join ', ')" }
        Remove-Item -LiteralPath $addonDir -Recurse -Force
    }
}

if ($Remove) {
    Remove-Bridge
    Write-Host "Removed $addonDir"
    return
}

# --- find the account ------------------------------------------------------------------
$accountRoot = Join-Path $ClientPath 'WTF\Account'
if (-not (Test-Path -LiteralPath $accountRoot)) { throw "no WTF\Account under $ClientPath - log in once first." }

if (-not $Account) {
    $candidates = Get-ChildItem -LiteralPath $accountRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SavedVariables') } |
        Sort-Object {
            $file = Join-Path $_.FullName 'SavedVariables\AKForeverWeaponBuffs.lua'
            if (Test-Path -LiteralPath $file) { (Get-Item -LiteralPath $file).LastWriteTime } else { [datetime]::MinValue }
        } -Descending
    if (-not $candidates) { throw "no account with a SavedVariables folder under $accountRoot" }
    $Account = @($candidates)[0].Name
}
$accountDir = Join-Path $accountRoot $Account
$svDir = Join-Path $accountDir 'SavedVariables'
if (-not (Test-Path -LiteralPath $svDir)) { throw "not found: $svDir" }

$tocFiles = @('Before.lua', 'SV\AKForeverWeaponBuffs.lua')
$targets = @{ SV = $svDir }

if ($LegacyCharacterFolder) {
    $charDir = Join-Path (Join-Path $accountDir $LegacyCharacterFolder) 'SavedVariables'
    if (-not (Test-Path -LiteralPath (Join-Path $charDir 'AKForeverWeaponBuffs.lua'))) {
        throw "no AKForeverWeaponBuffs.lua under $charDir"
    }
    $targets.SVChar = $charDir
    $tocFiles += 'SVChar\AKForeverWeaponBuffs.lua'
}
$tocFiles += 'After.lua'

# The .toc names SV\AKForeverWeaponBuffs.lua; make sure it exists so a fresh install does not log
# "couldn't open". The client overwrites it on the next logout.
$svFile = Join-Path $svDir 'AKForeverWeaponBuffs.lua'
if (-not (Test-Path -LiteralPath $svFile)) { Set-Content -LiteralPath $svFile -Value '' -Encoding ascii }

# --- (re)build the companion addon -------------------------------------------------------
Remove-Bridge
New-Item -ItemType Directory -Path $addonDir | Out-Null

$toc = @(
    '## Interface: 16001'
    '## Title: AKForeverWeaponBuffs |cff888888(saved state bridge)|r'
    '## Notes: Beta workaround: the WoW: Forever client never reads SavedVariables back, so this loads AKForeverWeaponBuffs'' saved file as code. Remove it once Blizzard fixes that.'
    '## Author: Purrdee'
    '## Version: 1'
    ''
) + $tocFiles
Set-Content -LiteralPath (Join-Path $addonDir 'AKForeverWeaponBuffs_SavedState.toc') -Value $toc -Encoding ascii

Set-Content -LiteralPath (Join-Path $addonDir 'Before.lua') -Encoding ascii -Value @(
    '-- Generated by AKForeverWeaponBuffs\tools\Install-SavedStateBridge.ps1.'
    'AKForeverWeaponBuffs_SavedStateBridge = { version = 1 }'
)
Set-Content -LiteralPath (Join-Path $addonDir 'After.lua') -Encoding ascii -Value @(
    '-- Lets AKForeverWeaponBuffs tell "loaded by this bridge" from "loaded by the client".'
    'AKForeverWeaponBuffs_SavedStateBridge.table = AKForeverWeaponBuffsDB'
)

foreach ($name in $targets.Keys) {
    New-Item -ItemType Junction -Path $links[$name] -Target $targets[$name] | Out-Null
}

Write-Host "Installed $addonDir"
Write-Host "  account : $Account"
foreach ($name in $targets.Keys) { Write-Host ("  {0,-7} -> {1}" -f $name, $targets[$name]) }
Write-Host 'Restart the game client completely - a new addon folder is not picked up by /reload.'
