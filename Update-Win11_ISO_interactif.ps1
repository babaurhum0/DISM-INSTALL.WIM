<# =====================================================================
   RUNBOOK WINDOWS 11 25H2 – STRICT INDEX (COMPACT N1)
===================================================================== #>

# --- RESET ENVIRONNEMENT ---
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)

# --- Verification visuelle ADMIN + PS 5.1 ---
$psVer = $PSVersionTable.PSVersion
if (-not ($psVer -and $psVer.Major -eq 5 -and $psVer.Minor -ge 1)) { Write-Host "Avertissement : conçu pour PowerShell 5.1." -ForegroundColor Yellow }
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "Avertissement : pas en mode administrateur. Certaines opérations peuvent échouer." -ForegroundColor Yellow }

# --- CONFIGURATION ADK ---
$ADKPath  = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64"
$Dism     = Join-Path $ADKPath "DISM\dism.exe"
$Oscdimg  = Join-Path $ADKPath "Oscdimg\oscdimg.exe"
$BootBIOS = Join-Path $ADKPath "Oscdimg\etfsboot.com"
$BootUEFI = Join-Path $ADKPath "Oscdimg\efisys_noprompt.bin"

# --- CHEMINS ---
$Root="D:\SSULCU_WIN11"
$ISO="$Root\Win11ISO"
$UPD="$Root\25H2_updates"
$MNT_I="$Root\Mount_Install"
$OutISO="$Root\Win11_25H2_Pro_Custom.iso"

# --- RAZ VARIABLES ---
$global:InstallIndex=$null
$global:DotNet=$null
$global:LCU=$null
$global:OOB=$null
$global:DriversAMD=$false
$ExitMenu=$false

function Out { param($Msg,$Color="White") ; Write-Host $Msg -ForegroundColor $Color }

Out "=== RUNBOOK WINDOWS 11 25H2 – STRICT INDEX ===" "Cyan"

# =====================================================================
# 1. CORE — Fonctions fondamentales
# =====================================================================

function Assert-Mounted {
    if (-not (Test-Path "$MNT_I\Windows\System32")) { Out "→ ERREUR : aucune image montée." "Red" ; return $false }
    return $true
}

function Require-Index {
    if (-not $global:InstallIndex) { Out "→ ERREUR : aucun index défini. Option 1 obligatoire." "Red" ; return $false }
    return $true
}

function Init-MountDirs {
    if (-not (Test-Path $MNT_I)) { New-Item -ItemType Directory -Path $MNT_I | Out-Null }
}

# =====================================================================
# 2. CONTEXTE — Sélection index + détection KB
# =====================================================================

function Select-InstallIndex {
    if (-not (Test-Path "$ISO\sources\install.wim")) { Out "ERREUR : install.wim introuvable." "Red" ; return $false }
    $info = (& $Dism /get-wiminfo /wimfile:"$ISO\sources\install.wim") | Where-Object { $_.Trim() -ne "" }
    if ($LASTEXITCODE -ne 0) { Out "ERREUR lecture index." "Red" ; return $false }

    $entries = @()
    for ($i = 0; $i -lt $info.Count; $i++) {
        $line = $info[$i].Trim()
        if ($line -like "Index*") {
            $idx = ($line.Split(":",2)[1]).Trim()
            $raw = $info[$i+1].Trim()
            if ($raw -like "Name*") { $name = ($raw.Split(":",2)[1]).Trim() }
            elseif ($raw -like "Nom*") { $name = ($raw.Split(":",2)[1]).Trim() }
            else { $name = "Inconnu" }
            $entries += [PSCustomObject]@{ Index=[int]$idx ; Name=$name }
        }
    }

    if (-not $entries) { Out "Aucune édition trouvée dans install.wim." "Red" ; return $false }

    Out "[INDEX] Liste des éditions disponibles :" "Yellow"
    foreach ($e in $entries) { Out "[$($e.Index)] $($e.Name)" "Cyan" }

    # Boucle de saisie : redemande tant que l'entrée n'est pas un entier valide et présent dans la liste
    do {
        $rawChoice = Read-Host "Choisissez un index"
        $parsed = 0
        if (-not [int]::TryParse($rawChoice, [ref]$parsed)) {
            Out "Index invalide (doit être un nombre)." "Red"
            continue
        }
        $choice = [int]$parsed
        if ($entries.Index -notcontains $choice) {
            Out "Index non présent dans la liste." "Red"
            continue
        }
        break
    } while ($true)

    $global:InstallIndex = $choice
    Out "Index sélectionné : $global:InstallIndex" "Green"
    return $true
}


function Prepare-IntegrationContext {
    if (-not (Test-Path $UPD)) { Out "ERREUR : dossier KB introuvable." "Red" ; return $false }

    if (-not (Select-InstallIndex)) { return $false }

    $kbList = Get-ChildItem "$UPD\*.msu"
    foreach ($kb in $kbList) {
        Out "KB : $($kb.Name)" "Cyan"
        Out "1=.NET  2=LCU  3=OOB  4=Ignorer"
        switch (Read-Host "Choix") {
            "1" { $global:DotNet = $kb.FullName }
            "2" { $global:LCU   = $kb.FullName }
            "3" { $global:OOB   = $kb.FullName }
        }
    }

    $global:DriversAMD = Test-Path "$UPD\DRIVERS_AMD\Binaries"
    return $true
}

# =====================================================================
# 3. DISM / WIM — Opérations sur l’image
# =====================================================================

function Mount-Wim {
    param($Wim,$Index,$Mount)
    Out "[MOUNT] Index $Index → $Mount" "Yellow"
    & "$Dism" /mount-wim /wimfile:"$Wim" /index:$Index /mountdir:"$Mount"
    if ($LASTEXITCODE -ne 0) { Out "→ ERREUR montage." "Red" ; return }
    Out "→ OK." "Green"
}

function Unmount-Wim { Out "[UNMOUNT] Commit..." "Yellow" ; & "$Dism" /unmount-wim /mountdir:"$MNT_I" /commit }

function Add-PackageSafe {
    param($Image,$Package)
    if (-not (Assert-Mounted)) { return }
    if (-not (Test-Path $Package)) { Out "→ ERREUR : package introuvable : $Package" "Red" ; return }
    Out "[PACKAGE] Ajout : $Package" "Yellow"
    & "$Dism" /image:"$Image" /add-package /packagepath:"$Package"
    if ($LASTEXITCODE -ne 0) { Out "→ ERREUR : échec de l’application." "Red" ; return }
    Out "→ OK." "Green"
}

function Add-Drivers {
    if (-not $global:DriversAMD) { Out "→ Drivers AMD absents." "Red" ; return }
    Out "[DRIVERS] Injection..." "Yellow"
    & "$Dism" /image:"$MNT_I" /add-driver /driver:"$UPD\DRIVERS_AMD\Binaries" /recurse
}

function Cleanup-Images {
    Out "[CLEANUP] SCC + ResetBase..." "Yellow"
    & "$Dism" /image:"$MNT_I" /cleanup-image /startcomponentcleanup /resetbase
}

# =====================================================================
# 4. ISO — Reconstruction ISO
# =====================================================================

function Build-ISO {
    Out "[ISO] Reconstruction..." "Yellow"
    if (Test-Path $OutISO) { Remove-Item $OutISO -Force }
    & "$Oscdimg" "-bootdata:2#p0,e,b$BootBIOS#pEF,e,b$BootUEFI" "-u2" "-udfver102" "-lWIN11_25H2_PRO" "-m" "-o" $ISO $OutISO
}

# =====================================================================
# 5. MAINTENANCE — Discard / Nettoyage
# =====================================================================

function Force-Discard-Mounts {
    & $Dism /unmount-wim /mountdir:"$MNT_I" /discard
    if (Test-Path $MNT_I) {
        Remove-Item -Path $MNT_I -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $MNT_I | Out-Null
    }
    & $Dism /cleanup-wim
}

# =====================================================================
# 6. PIPELINE — Intégration complète
# =====================================================================

function Full-Integration {
    if (-not (Require-Index)) { return }
    Init-MountDirs
    if (-not (Test-Path "$ISO\sources\install.wim")) { Out "→ ERREUR : install.wim introuvable." "Red" ; return }
    Mount-Wim "$ISO\sources\install.wim" $InstallIndex "$MNT_I"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$MNT_I\Windows\System32")) { Out "→ Abandon : montage impossible, intégration annulée." "Red" ; return }
    Add-Drivers
    if ($DotNet) { Add-PackageSafe "$MNT_I" "$DotNet" }
    if ($LCU)    { Add-PackageSafe "$MNT_I" "$LCU" }
    if ($OOB)    { Add-PackageSafe "$MNT_I" "$OOB" }
    Cleanup-Images
    Unmount-Wim
    Build-ISO
}

# =====================================================================
# 7. UI — Menu + boucle
# =====================================================================

function Show-Menu {
    Out ""
    Out "=== MENU ===" "Cyan"
    Out "1. Détection des KB + Index"
    Out "2. Intégration complète"
    Out "3. Montage (install.wim)"
    Out "4. Drivers AMD"
    Out "5. .NET (KB marquée)"
    Out "6. LCU (KB marquée)"
    Out "7. OOB (KB marquée)"
    Out "8. Optimiser image (StartComponentCleanup + ResetBase)"
    Out "9. Démontage (commit)"
    Out "10. Reconstruction ISO"
    Out "11. Forcer discard"
    Out "12. Quitter"
}

do {
    Show-Menu
    switch (Read-Host "Votre choix") {
        "1"  { Prepare-IntegrationContext }
        "2"  { if (Require-Index) { Full-Integration } }
        "3"  { if (Require-Index) { Init-MountDirs ; Mount-Wim "$ISO\sources\install.wim" $InstallIndex "$MNT_I" } }
        "4"  { if (Assert-Mounted) { Add-Drivers } }
        "5"  { if (Assert-Mounted -and $DotNet) { Add-PackageSafe "$MNT_I" "$DotNet" } }
        "6"  { if (Assert-Mounted -and $LCU)    { Add-PackageSafe "$MNT_I" "$LCU" } }
        "7"  { if (Assert-Mounted -and $OOB)    { Add-PackageSafe "$MNT_I" "$OOB" } }
        "8"  { if (Assert-Mounted) { Cleanup-Images } }
        "9"  { if (Assert-Mounted) { Unmount-Wim } }
        "10" { Build-ISO }
        "11" { Force-Discard-Mounts }
        "12" { Out "Sortie." "Cyan" ; $ExitMenu=$true }
        default { Out "Choix invalide." "Red" }
    }
} while (-not $ExitMenu)
