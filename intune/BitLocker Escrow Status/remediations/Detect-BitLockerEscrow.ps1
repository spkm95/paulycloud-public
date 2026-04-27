<#
.SYNOPSIS
    Detection script for Intune remediation: checks whether a BitLocker recovery key
    is escrowed to Entra ID or Active Directory for the OS drive.

.DESCRIPTION
    Exits 0 (compliant) if a RecoveryPassword protector exists and an event log entry
    confirms it has been successfully backed up to AAD (Event 845) or AD DS (Event 775).
    Exits 1 (non-compliant) to trigger the remediation script.

.NOTES
    Run context: SYSTEM, 64-bit
    Event ID 845 = "BitLocker recovery information was backed up successfully to Azure AD"
    Event ID 775 = "BitLocker recovery information was backed up successfully to Active Directory"

    Author:  Simon Pauly Kofoed Mose
    Blog:    https://paulycloud.com
    Version: 1.1 - Added on-prem AD escrow detection (Event ID 775)
             1.0 - Initial release
#>

try {
    $osDrive = $env:SystemDrive
    $volume  = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop

    if ($volume.VolumeStatus -eq "FullyDecrypted") {
        Write-Host "Non-compliant - Drive not encrypted"
        exit 1
    }

    $recoveryProtectors = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }

    if (-not $recoveryProtectors) {
        Write-Host "Non-compliant - No RecoveryPassword protector found"
        exit 1
    }

    $protectorIds = $recoveryProtectors | Select-Object -ExpandProperty KeyProtectorId

    # Event 845 = AAD/Entra escrow, Event 775 = on-prem AD escrow
    $events = Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -ErrorAction SilentlyContinue |
                  Where-Object { $_.Id -eq 845 -or $_.Id -eq 775 }

    $escrowTarget = $null
    foreach ($id in $protectorIds) {
        $cleanId = $id.Trim("{}")
        $match = $events | Where-Object { $_.Message -like "*$cleanId*" } | Select-Object -First 1
        if ($match) {
            $escrowTarget = if ($match.Id -eq 845) { "Entra ID" } else { "Active Directory" }
            break
        }
    }

    if ($escrowTarget) {
        Write-Host "Compliant - Confirmed escrow to $escrowTarget"
        exit 0
    } else {
        Write-Host "Non-compliant - Key not escrowed"
        exit 1
    }
} catch {
    Write-Host "Non-compliant - Detection error: $_"
    exit 1
}
