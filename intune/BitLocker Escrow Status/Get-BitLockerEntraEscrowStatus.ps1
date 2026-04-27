<#
.SYNOPSIS
    Reports whether BitLocker recovery keys are escrowed to Entra ID for Windows devices.

.DESCRIPTION
    Queries Microsoft Graph for BitLocker recovery keys stored in Entra ID (Azure AD).
    This report does NOT include keys escrowed to on-premises Active Directory.
    Uses Microsoft.Graph.Authentication and native Invoke-MgGraphRequest calls.
    Windows 365 Cloud PC devices are excluded.

    Required Graph API permissions:
      - Device.Read.All
      - BitLockerKey.ReadBasic.All
      - DeviceManagementManagedDevices.Read.All

.NOTES
    Run once to install the module:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force

    Author:  Simon Pauly Kofoed Mose
    Blog:    https://paulycloud.com
    Version: 1.1 - Clarified Entra-only scope; renamed script
             1.0 - Initial release
#>

# ── Variables ─────────────────────────────────────────────────────────────────
$baseUri = "https://graph.microsoft.com/beta"
$scopes  = @(
    "Device.Read.All",
    "BitLockerKey.ReadBasic.All",
    "DeviceManagementManagedDevices.Read.All"
)

# ── Functions ─────────────────────────────────────────────────────────────────

function Initialize-MgGraphModule {
    if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Authentication")) {
        Write-Host "Installing Microsoft.Graph.Authentication..." -ForegroundColor Yellow
        Install-Module "Microsoft.Graph.Authentication" -Scope CurrentUser -Force
    }
    Import-Module "Microsoft.Graph.Authentication" -ErrorAction Stop
    Write-Host "Microsoft.Graph.Authentication module loaded." -ForegroundColor Green
}

function Invoke-MgGraphRequestAll {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri -OutputType PSObject
        if ($response.value) { $results.AddRange($response.value) }
        $nextUri = $response.'@odata.nextLink'
    } while ($nextUri)
    return $results
}

function Connect-Graph {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Connect-MgGraph -Scopes $scopes -ContextScope Process -NoWelcome
    Write-Host "Connected to Microsoft Graph." -ForegroundColor Green
}

function Get-WindowsDevices {
    Write-Host "Fetching Windows devices from Entra..." -ForegroundColor Cyan
    $script:devices = Invoke-MgGraphRequestAll -Uri "$baseUri/devices?`$select=id,displayName,deviceId,operatingSystem,approximateLastSignInDateTime" |
        Where-Object { $_.operatingSystem -eq "Windows" }
    Write-Host "  Found $($script:devices.Count) Windows device(s)." -ForegroundColor Cyan
}

function Get-BitLockerKeys {
    Write-Host "Fetching BitLocker recovery keys..." -ForegroundColor Cyan
    $script:bitlockerMap = @{}
    Invoke-MgGraphRequestAll -Uri "$baseUri/informationProtection/bitlocker/recoveryKeys" |
        ForEach-Object {
            $id      = $_.deviceId
            $created = $_.createdDateTime
            if (-not $script:bitlockerMap.ContainsKey($id) -or $created -gt $script:bitlockerMap[$id]) {
                $script:bitlockerMap[$id] = $created
            }
        }
    Write-Host "  Found keys for $($script:bitlockerMap.Count) device(s)." -ForegroundColor Cyan
}

function Get-IntuneDeviceInfo {
    Write-Host "Fetching Intune managed device info..." -ForegroundColor Cyan
    $script:intuneMap  = @{}
    $script:cloudPcIds = @{}
    Invoke-MgGraphRequestAll -Uri "$baseUri/deviceManagement/managedDevices?`$select=id,azureADDeviceId,operatingSystem,lastSyncDateTime,model&`$filter=operatingSystem eq 'Windows'" |
        ForEach-Object {
            $script:intuneMap[$_.azureADDeviceId] = @{ Id = $_.id; LastSync = $_.lastSyncDateTime; Model = $_.model }
            if ($_.model -and $_.model -match "Cloud PC") {
                $script:cloudPcIds[$_.azureADDeviceId] = $true
            }
        }
    Write-Host "  Found $($script:intuneMap.Count) Intune device(s), $($script:cloudPcIds.Count) Cloud PC(s) excluded." -ForegroundColor Cyan
}

function Build-Report {
    Write-Host "Analyzing..." -ForegroundColor Yellow
    $script:report = foreach ($device in $script:devices) {
        $aadId = $device.deviceId

        # Skip Windows 365 Cloud PCs
        if ($script:cloudPcIds.ContainsKey($aadId)) { continue }

        # Match against both hardware deviceId and directory object id
        $escrowed   = $script:bitlockerMap.ContainsKey($aadId) -or $script:bitlockerMap.ContainsKey($device.id)
        $keyCreated = if ($script:bitlockerMap.ContainsKey($aadId)) { $script:bitlockerMap[$aadId] } else { $script:bitlockerMap[$device.id] }

        [PSCustomObject]@{
            DeviceName        = $device.displayName
            DeviceId          = $aadId
            IntuneDeviceId    = $script:intuneMap[$aadId]?.Id
            Model             = $script:intuneMap[$aadId]?.Model
            EscrowStatus      = if ($escrowed) { "YES" } else { "NO" }
            KeyCreated        = $keyCreated
            LastIntuneSync    = $script:intuneMap[$aadId]?.LastSync
            LastEntraActivity = $device.approximateLastSignInDateTime
        }
    }
}

function Show-Summary {
    $withKey    = ($script:report | Where-Object { $_.EscrowStatus -eq "YES" }).Count
    $withoutKey = ($script:report | Where-Object { $_.EscrowStatus -eq "NO" }).Count
    Write-Host "---------------------------------" -ForegroundColor Gray
    Write-Host "Devices with escrowed key   : $withKey"    -ForegroundColor Green
    Write-Host "Devices without escrowed key: $withoutKey" -ForegroundColor Red
    Write-Host "---------------------------------" -ForegroundColor Gray
}

function Export-Report {
    $reportsDir = Join-Path $PSScriptRoot "reports"
    if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir | Out-Null }

    $tenantId = (Invoke-MgGraphRequest -Method GET -Uri "$baseUri/organization?`$select=id" -OutputType PSObject).value[0].id
    $date     = Get-Date -Format "yyyy-MM-dd_HHmm"
    $baseName = "BitLockerEntraEscrow_${tenantId}_${date}"

    $csvPath = Join-Path $reportsDir "$baseName.csv"
    $script:report | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV saved: $csvPath" -ForegroundColor Cyan

    return $reportsDir
}

# ── Execution ─────────────────────────────────────────────────────────────────

$reportsDir = Join-Path $PSScriptRoot "reports"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir | Out-Null }
$transcriptPath = Join-Path $reportsDir "BitLockerEntraEscrow_$(Get-Date -Format 'yyyy-MM-dd_HHmm').log"
Start-Transcript -Path $transcriptPath -Force

try {
    Initialize-MgGraphModule
    Connect-Graph
    Get-WindowsDevices
    Get-BitLockerKeys
    Get-IntuneDeviceInfo
    Build-Report
    Show-Summary
    Export-Report
} finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    Stop-Transcript
}
