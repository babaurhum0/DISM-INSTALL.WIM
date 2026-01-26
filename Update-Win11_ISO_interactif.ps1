<# =====================================================================
   RUNBOOK WINDOWS 11 25H2 – BASELINE INSTALL.WIM UNIQUEMENT
   - Détection manuelle des KB (.NET / LCU / OOB)
   - Anti-montage blindé
   - Vérification ADK / ISO / WIM
   - Logging complet (console + fichier)
===================================================================== #>

# --- CONFIGURATION ADK ---
$ADKPath  = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64"
$Dism     = Join-Path $ADKPath "DISM\dism.exe"
$Oscdimg  = Join-Path $ADKPath "Oscdimg\oscdimg.exe"
$BootBIOS = Join-Path $ADKPath "Oscdimg\etfsboot.com"
$BootUEFI = Join-Path $ADKPath "Oscdimg\efisys_noprompt.bin"

# --- CHEMINS DE TRAVAIL ---
$Root     = "D:\SSULCU_WIN11"
$ISO      = "$Root\Win11ISO"
$UPD      = "$Root\25H2_updates"
$MNT_I    = "$Root\Mount_Install"
$OutISO   = "$Root\Win11_25H2_Pro_Custom.iso"

# --- LOGGING ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile   = Join-Path $ScriptDir ("Log-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

function Out {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
    Write-Log $Message
}

Out "=== RUNBOOK WINDOWS 11 25H2 – VERSION INSTALL.WIM UNIQUEMENT ===" "Cyan"
Out "Log : $LogFile" "DarkGray"

# --- VÉRIFICATION ADK / OUTILS ---
if (-not (Test-Path $Dism))    { Out "ERREUR : DISM ADK introuvable : $Dism" "Red" ; exit 1 }
if (-not (Test-Path $Oscdimg)) { Out "ERREUR : Oscdimg introuvable : $Oscdimg" "Red" ; exit 1 }
if (-not (Test-Path $BootBIOS)) { Out "ERREUR : Etfsboot.com introuvable : $BootBIOS" "Red" ; exit 1 }
if (-not (Test-Path $BootUEFI)) { Out "ERREUR : efisys_noprompt.bin introuvable : $BootUEFI" "Red" ; exit 1 }

Out "Outils ADK détectés correctement." "Green"


# =====================================================================
# FONCTIONS UTILITAIRES
# =====================================================================

function Assert-Mounted {
    if (-not (Test-Path "$MNT_I\Windows")) {
        Out "→ ERREUR : aucune image montée dans $MNT_I." "Red"
        return $false
    }
    return $true
}

# =====================================================================
# NOUVELLE FONCTION : FORCE DISCARD
# =====================================================================

function Force-Discard-Mounts {
    Out "[FORCE DISCARD] Recherche des montages actifs..." "Yellow"

    $mounts = & "$Dism" /get-mountedwiminfo 2>$null | Select-String "Mount Dir :"

    if (-not $mounts) {
        Out "→ Aucun montage actif détecté." "DarkGray"
        return
    }

    foreach ($line in $mounts) {
        $path = $line.ToString().Split(":")[1].Trim()
        Out "→ Montage détecté : $path" "Red"
        Out "  → Démontage forcé /discard..." "DarkGray"

        & "$Dism" /unmount-wim /mountdir:"$path" /discard

        if ($LASTEXITCODE -ne 0) {
            Out "  → ERREUR : échec du discard (code $LASTEXITCODE)" "Red"
        } else {
            Out "  → Montage supprimé." "Green"
        }
    }
}

# =====================================================================
# DÉTECTION MANUELLE DES KB
# =====================================================================

function Detect-Updates {

    Out "[DETECT] Analyse des KB dans le dossier : $UPD" "Yellow"

    $kbList = Get-ChildItem "$UPD\*.msu" -ErrorAction SilentlyContinue

    if (-not $kbList) {
        Out "→ Aucune KB trouvée dans $UPD" "Red"
        return
    }

    $global:DotNet     = $null
    $global:LCU        = $null
    $global:OOB        = $null
    $global:DriversAMD = Test-Path "$UPD\DDU_AMD\Binaries"

    foreach ($kb in $kbList) {

        Out "" "White"
        Out "KB détectée : $($kb.Name)" "Cyan"

        Out "Type de KB ?" "Yellow"
        Out "  1 = .NET" "White"
        Out "  2 = LCU" "White"
        Out "  3 = OOB" "White"
        Out "  4 = Ignorer" "White"

        $choice = Read-Host "Votre choix"

        switch ($choice) {
            "1" {
                $global:DotNet = $kb.FullName
                Out "→ Marquée comme .NET" "Green"
            }
            "2" {
                $global:LCU = $kb.FullName
                Out "→ Marquée comme LCU" "Green"
            }
            "3" {
                $global:OOB = $kb.FullName
                Out "→ Marquée comme OOB" "Green"
            }
            "4" {
                Out "→ Ignorée" "DarkGray"
            }
            default {
                Out "→ Choix invalide, ignorée." "Red"
            }
        }
    }

    Out "" "White"
    Out "=== RÉCAPITULATIF ===" "Cyan"
    Out ".NET : $DotNet" "White"
    Out "LCU  : $LCU" "White"
    Out "OOB  : $OOB" "White"

    if ($DriversAMD) { Out "Drivers AMD : OK ($UPD\DDU_AMD\Binaries)" "Green" }
    else             { Out "Drivers AMD : ABSENTS" "Red" }
}

# =====================================================================
# MONTAGE / INTÉGRATION / CLEANUP
# =====================================================================

function Init-MountDirs {
    Out "[INIT] Vérification des dossiers de montage..." "Yellow"
    if (-not (Test-Path $MNT_I)) {
        Out "→ Création : $MNT_I" "Green"
        New-Item -ItemType Directory -Path $MNT_I | Out-Null
    } else {
        Out "→ OK : $MNT_I" "DarkGray"
    }
}

function Cleanup-ExistingMounts {
    Out "[CLEANUP] Vérification des montages existants..." "Yellow"
    $mounts = & "$Dism" /get-mountedwiminfo 2>$null | Select-String "Mount Dir :"
    if (-not $mounts) {
        Out "→ Aucun montage existant détecté." "DarkGray"
        return
    }

    foreach ($line in $mounts) {
        $path = $line.ToString().Split(":")[1].Trim()
        Out "→ Montage existant détecté : $path" "Red"
        $ans = Read-Host "  Voulez-vous le démonter avec /discard ? (O/N)"
        if ($ans -match "^[Oo]$") {
            Out "  Démontage /discard..." "DarkGray"
            & "$Dism" /unmount-wim /mountdir:"$path" /discard
        } else {
            Out "  Laisser le montage en place." "Yellow"
        }
    }
}

function Mount-Wim {
    param($Wim, $Index, $Mount)

    Out "[MOUNT] $Wim (index $Index) → $Mount" "Yellow"

    if (-not (Test-Path $Wim)) {
        Out "→ ERREUR : fichier WIM introuvable." "Red"
        return
    }

    if (Test-Path "$Mount\Windows") {
        Out "→ ATTENTION : $Mount semble déjà contenir une image montée." "Red"
        $ans = Read-Host "  Forcer quand même le montage ? (O/N)"
        if ($ans -notmatch "^[Oo]$") {
            Out "→ Montage annulé." "Yellow"
            return
        }
    }

    & "$Dism" /mount-wim /wimfile:"$Wim" /index:$Index /mountdir:"$Mount"
    if ($LASTEXITCODE -ne 0) {
        Out "→ ERREUR : échec du montage (code $LASTEXITCODE)" "Red"
        return
    }

    Out "→ Montage réussi." "Green"
}

function Add-PackageSafe {
    param($Image, $Package)

    if (-not (Test-Path $Package)) {
        Out "→ ERREUR : package introuvable : $Package" "Red"
        return
    }

    Out "[PACKAGE] Ajout : $Package" "Yellow"
    & "$Dism" /image:"$Image" /add-package /packagepath:"$Package"

    if ($LASTEXITCODE -ne 0) {
        Out "→ ERREUR : échec de l’application du package (code $LASTEXITCODE)" "Red"
        return
    }

    Out "→ Package appliqué." "Green"
}

function Add-Drivers {
    Out "[DRIVERS] Injection des drivers AMD..." "Yellow"

    if (-not $DriversAMD) {
        Out "→ Drivers AMD absents." "Red"
        return
    }

    & "$Dism" /image:"$MNT_I" /add-driver /driver:"$UPD\DDU_AMD\Binaries" /recurse

    if ($LASTEXITCODE -ne 0) {
        Out "→ ERREUR : échec de l’installation des drivers (code $LASTEXITCODE)" "Red"
        return
    }

    Out "→ Drivers installés." "Green"
}

function Cleanup-Images {
    Out "[CLEANUP] Optimisation de l'image INSTALL (SCC + ResetBase)..." "Yellow"

    & "$Dism" /image:"$MNT_I" /cleanup-image /startcomponentcleanup /resetbase

    if ($LASTEXITCODE -ne 0) {
        Out "→ ERREUR : cleanup échoué (code $LASTEXITCODE)" "Red"
        return
    }

    Out "→ Cleanup terminé." "Green"
}

function Unmount-Wim {
    param($Mount)

    Out "[UNMOUNT] Démontage : $Mount" "Yellow"

    & "$Dism" /unmount-wim /mountdir:"$Mount" /commit

    if ($LASTEXITCODE -ne 0) {
        Out "→ ERREUR : commit impossible, rollback..." "Red"
        & "$Dism" /unmount-wim /mountdir:"$Mount" /discard
        return
    }

    Out "→ Démonté avec succès." "Green"
}

function Build-ISO {

    Out "[ISO] Reconstruction de l’image ISO..." "Yellow"

    if (-not (Test-Path $ISO)) {
        Out "→ ERREUR : dossier source ISO introuvable : $ISO" "Red"
        return
    }

    if (-not (Test-Path "$ISO\sources\install.wim")) {
        Out "→ ERREUR : install.wim introuvable dans $ISO\sources" "Red"
        return
    }

    if (-not (Test-Path "$ISO\sources\boot.wim")) {
        Out "→ ERREUR : boot.wim introuvable dans $ISO\sources" "Red"
        return
    }

    if (Test-Path $OutISO) {
        Out "→ Suppression de l’ancienne ISO..." "DarkGray"
        Remove-Item $OutISO -Force -ErrorAction SilentlyContinue
    }

    $OscArgs = @(
        "-bootdata:2#p0,e,b$BootBIOS#pEF,e,b$BootUEFI",
        "-u2","-udfver102","-lWIN11_25H2_PRO","-m","-o",
        $ISO, $OutISO
    )

    & "$Oscdimg" @OscArgs

    if ($LASTEXITCODE -ne 0) {
        Out "→ ERREUR : échec de la génération ISO (code $LASTEXITCODE)" "Red"
        return
    }

    Out "→ ISO générée : $OutISO" "Green"
}

# =====================================================================
# INTÉGRATION COMPLÈTE
# =====================================================================

function Full-Integration {

    Out "`n=== INTÉGRATION COMPLÈTE ===" "Cyan"

    Detect-Updates

    Init-MountDirs
    Cleanup-ExistingMounts

    Mount-Wim "$ISO\sources\install.wim" 6 "$MNT_I"
    if (-not (Test-Path "$MNT_I\Windows")) {
        Out "→ ERREUR : montage INSTALL invalide, arrêt de l’intégration." "Red"
        return
    }

    Add-Drivers

    if ($DotNet) { Add-PackageSafe "$MNT_I" "$DotNet" }
    if ($LCU)    { Add-PackageSafe "$MNT_I" "$LCU" }
    if ($OOB)    { Add-PackageSafe "$MNT_I" "$OOB" }

    Cleanup-Images

    Unmount-Wim "$MNT_I"

    Build-ISO

    Out "`n=== INTÉGRATION TERMINÉE ===" "Green"
}

# =====================================================================
# MENU INTERACTIF
# =====================================================================

function Show-Menu {
    Out "" "White"
    Out "=== MENU ===" "Cyan"
    Out "1. Détection des KB" "White"
    Out "2. Intégration complète" "White"
    Out "3. Montage (install.wim)" "White"
    Out "4. Drivers AMD" "White"
    Out "5. .NET (KB marquée)" "White"
    Out "6. LCU (KB marquée)" "White"
    Out "7. OOB (KB marquée)" "White"
    Out "8. Cleanup (SCC + ResetBase)" "White"
    Out "9. Démontage (commit)" "White"
    Out "10. Reconstruction ISO" "White"
    Out "11. Forcer discard des montages actifs" "White"
    Out "12. Quitter" "White"
    Out "" "White"
}

do {
    Show-Menu
    $choice = Read-Host "Votre choix"

    switch ($choice) {

        "1"  { Detect-Updates }

        "2"  { Full-Integration }

        "3"  {
            Init-MountDirs
            Cleanup-ExistingMounts
            Mount-Wim "$ISO\sources\install.wim" 6 "$MNT_I"
        }

        "4"  {
            if (Assert-Mounted) { Add-Drivers }
        }

        "5"  {
            if (Assert-Mounted) {
                if ($DotNet) { Add-PackageSafe "$MNT_I" "$DotNet" }
                else { Out "→ KB .NET non définie." "Red" }
            }
        }

        "6"  {
            if (Assert-Mounted) {
                if ($LCU) { Add-PackageSafe "$MNT_I" "$LCU" }
                else { Out "→ LCU non définie." "Red" }
            }
        }

        "7"  {
            if (Assert-Mounted) {
                if ($OOB) { Add-PackageSafe "$MNT_I" "$OOB" }
                else { Out "→ OOB non définie." "Red" }
            }
        }

        "8"  {
            if (Assert-Mounted) { Cleanup-Images }
        }

        "9"  {
            if (Assert-Mounted) { Unmount-Wim "$MNT_I" }
        }

        "10" { Build-ISO }

        "11" { Force-Discard-Mounts }

        "12" {
            Out "Sortie." "Cyan"
            $global:ExitMenu = $true
        }

        default { Out "Choix invalide." "Red" }
    }

} while (-not $ExitMenu)
