# Avatar Rules for Spirit City: Lofi Sessions: installs or removes the mod. ASCII only.
# Finds the game in the Steam libraries. -Dossier gives the game folder by hand.
# It shares UE4SS with any other UE4SS mod. The marker file below means "UE4SS came with a mod, nobody installed it on purpose":
# whichever mod leaves last takes UE4SS away with it. Without the marker, UE4SS was there before and it is never removed.
param([string]$Action = 'install', [string]$Dossier = '', [switch]$SansQuestion)
$ErrorActionPreference = 'Stop'
$ici = Split-Path -Parent $MyInvocation.MyCommand.Path
$NomJeu = 'Spirit City Lofi Sessions'

function Trouver-Jeu {
    $racines = New-Object System.Collections.ArrayList
    $cles = 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam'
    foreach ($cle in $cles) {
        $p = Get-ItemProperty $cle -ErrorAction SilentlyContinue
        foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { [void]$racines.Add($v) } }
    }
    foreach ($r in @($racines)) {
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                [void]$racines.Add($m.Groups[1].Value.Replace('\\', '\'))
            }
        }
    }
    foreach ($r in $racines) {
        $d = Join-Path $r "steamapps\common\$NomJeu"
        if (Test-Path (Join-Path $d 'SpiritCity\Binaries\Win64\SpiritCity-Win64-Shipping.exe')) { return $d }
    }
    return $null
}

if (-not $Dossier) { $Dossier = Trouver-Jeu }
if (-not $Dossier -and -not $SansQuestion) {
    Write-Host 'Game folder not found automatically.'
    Write-Host 'In Steam: right click the game, Manage, Browse local files, then copy that folder path here.'
    $Dossier = (Read-Host 'Game folder').Trim('"', ' ')
}
$win64 = Join-Path $Dossier 'SpiritCity\Binaries\Win64'
if (-not $Dossier -or -not (Test-Path (Join-Path $win64 'SpiritCity-Win64-Shipping.exe'))) {
    Write-Host 'ERROR: this is not the Spirit City: Lofi Sessions folder. Nothing was changed.'
    exit 1
}
Write-Host "Game folder: $Dossier"
# An open game locks its files: wait for the player to close it, so nothing has to be started again.
if (Get-Process 'SpiritCity-Win64-Shipping' -ErrorAction SilentlyContinue) {
    if ($SansQuestion) {
        Write-Host 'ERROR: the game is open. Nothing was changed.'
        exit 1
    }
    Write-Host 'Please close the game. This continues by itself once it is closed.'
    while (Get-Process 'SpiritCity-Win64-Shipping' -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 2
}
$ue4ss = Join-Path $win64 'ue4ss'
$mods = Join-Path $ue4ss 'Mods'
$mod = Join-Path $mods 'AvatarRules'
$liste = Join-Path $mods 'mods.txt'
$marque = Join-Path $ue4ss 'RealScreen-installed-UE4SS.txt'

if ($Action -eq 'install') {
    $source = Join-Path $ici 'game\SpiritCity\Binaries\Win64'
    if (-not (Test-Path $source)) { Write-Host 'ERROR: unzip the whole archive first.'; exit 1 }
    $regles = $null
    if (Test-Path (Join-Path $mod 'regles.txt')) { $regles = [IO.File]::ReadAllText((Join-Path $mod 'regles.txt')) }
    if ((Test-Path (Join-Path $win64 'dwmapi.dll')) -and (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) {
        # UE4SS is already there: kept exactly as it is. Only this mod's folder is added.
        if (Test-Path $mod) { Remove-Item $mod -Recurse -Force }
        if (-not (Test-Path $mods)) { New-Item -ItemType Directory $mods | Out-Null }
        Copy-Item (Join-Path $source 'ue4ss\Mods\AvatarRules') $mods -Recurse -Force
        Write-Host 'UE4SS was already installed: kept as it is.'
    } else {
        Copy-Item (Join-Path $source '*') $win64 -Recurse -Force
        [IO.File]::WriteAllText($marque, "UE4SS was installed by a mod (Avatar Rules)`r`n")
    }
    if ($regles) { [IO.File]::WriteAllText((Join-Path $mod 'regles.txt'), $regles) }
    # Check by reading back.
    foreach ($f in 'Scripts\main.lua', 'enabled.txt', 'avatar_fenetres.dll') {
        if (-not (Test-Path (Join-Path $mod $f))) { Write-Host "ERROR: missing $f"; exit 1 }
    }
    foreach ($f in (Join-Path $win64 'dwmapi.dll'), (Join-Path $ue4ss 'UE4SS.dll')) {
        if (-not (Test-Path $f)) { Write-Host "ERROR: missing $f"; exit 1 }
    }
    Write-Host 'Installed. To set your rules: Options, Rules.'
} elseif ($Action -eq 'uninstall') {
    if (Test-Path $mod) { Remove-Item $mod -Recurse -Force }
    # A line left in the list by a mod that has already gone is cleaned up. Nothing else in the list is touched.
    if (Test-Path $liste) {
        $lignes = [IO.File]::ReadAllLines($liste) | Where-Object {
            $nom = ($_ -split ':')[0].Trim()
            -not ($nom -and $_ -match ': *[01]\s*$' -and -not (Test-Path (Join-Path $mods $nom)))
        }
        [IO.File]::WriteAllLines($liste, [string[]]@($lignes))
    }
    if (Test-Path $marque) {
        $autres = @(Get-ChildItem $mods -Directory -ErrorAction SilentlyContinue)
        if ($autres.Count -eq 0) {
            # UE4SS came with a mod and no mod is left: it goes too.
            Remove-Item $ue4ss -Recurse -Force
            Remove-Item (Join-Path $win64 'dwmapi.dll') -Force
            $logic = Join-Path $Dossier 'SpiritCity\Content\Paks\LogicMods'
            if ((Test-Path $logic) -and -not (Get-ChildItem $logic)) { Remove-Item $logic -Force }
        } else {
            Write-Host 'Other UE4SS mods found: UE4SS was kept.'
        }
    }
    if (Test-Path $mod) { Write-Host 'ERROR: the mod folder is still there.'; exit 1 }
    Write-Host 'Removed.'
} else {
    Write-Host "Unknown action: $Action"
    exit 1
}
