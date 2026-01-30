Prérequis :
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


=== MENU ===
1. Détection des KB + Index
2. Intégration complète
3. Montage (install.wim)
4. Drivers AMD
5. .NET (KB marquée)
6. LCU (KB marquée)
7. OOB (KB marquée)
8. Optimiser image (StartComponentCleanup + ResetBase)
9. Démontage (commit)
10. Reconstruction ISO
11. Forcer discard
12. Quitter
