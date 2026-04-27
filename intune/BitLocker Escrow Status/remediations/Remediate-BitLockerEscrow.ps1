<#
.SYNOPSIS
    Remediation script for Intune remediation: forces BitLocker recovery key escrow to Entra ID.

.DESCRIPTION
    Ensures a RecoveryPassword protector exists on the OS drive, adds one if missing,
    then backs up all recovery key protectors to Azure AD / Entra ID.

    Exits 0 on success, 1 on failure.

.NOTES
    Run context: SYSTEM, 64-bit

    Author:  Simon Pauly Kofoed Mose
    Blog:    https://paulycloud.com
    Version: 1.0 - Initial release
#>

try {
    $osDrive = $env:SystemDrive
    $volume  = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop

    if ($volume.VolumeStatus -eq "FullyDecrypted") {
        Write-Host "Failed - Drive not encrypted"
        exit 1
    }

    $recoveryProtectors = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }

    if (-not $recoveryProtectors) {
        Add-BitLockerKeyProtector -MountPoint $osDrive -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
        $volume             = Get-BitLockerVolume -MountPoint $osDrive
        $recoveryProtectors = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }
    }

    $failed = @()
    foreach ($protector in $recoveryProtectors) {
        try {
            BackupToAAD-BitLockerKeyProtector -MountPoint $osDrive -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop
        } catch {
            $failed += $protector.KeyProtectorId
        }
    }

    if ($failed.Count -eq 0) {
        Write-Host "Success - Key escrowed to Entra ID"
        exit 0
    } else {
        Write-Host "Failed - Could not escrow $($failed.Count) protector(s)"
        exit 1
    }
} catch {
    Write-Host "Failed - Remediation error: $_"
    exit 1
}
