<#
.SYNOPSIS
    Reports whether FileVault recovery keys are escrowed in Intune for macOS devices.

.DESCRIPTION
    Uses Microsoft.Graph.Authentication and native Invoke-MgGraphRequest calls.
    Only macOS / MacMDM devices are included.

    Required Graph API permissions:
      - Device.Read.All
      - DeviceManagementManagedDevices.Read.All
      - DeviceManagementManagedDevices.PrivilegedOperations.All  (required for getFileVaultKey)

.NOTES
    Run once to install the module:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force

    Author:  Simon Pauly Kofoed Mose
    Blog:    https://paulycloud.com
    Version: 1.0 - Initial release
#>

# ── Variables ─────────────────────────────────────────────────────────────────
$baseUri = "https://graph.microsoft.com/beta"
$scopes  = @(
    "Device.Read.All",
    "DeviceManagementManagedDevices.Read.All",
    "DeviceManagementManagedDevices.PrivilegedOperations.All"
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

function Get-MacDevices {
    Write-Host "Fetching macOS devices from Entra..." -ForegroundColor Cyan
    $script:devices = Invoke-MgGraphRequestAll -Uri "$baseUri/devices?`$select=id,displayName,deviceId,operatingSystem,approximateLastSignInDateTime" |
        Where-Object { $_.operatingSystem -in @("macOS", "MacMDM") }
    Write-Host "  Found $($script:devices.Count) macOS device(s)." -ForegroundColor Cyan
}

function Get-IntuneDeviceInfo {
    Write-Host "Fetching Intune managed device info..." -ForegroundColor Cyan
    $script:intuneMap    = @{}
    $script:fileVaultMap = @{}

    Invoke-MgGraphRequestAll -Uri "$baseUri/deviceManagement/managedDevices?`$select=id,azureADDeviceId,operatingSystem,lastSyncDateTime,model&`$filter=operatingSystem eq 'macOS'" |
        ForEach-Object {
            $script:intuneMap[$_.azureADDeviceId] = @{ Id = $_.id; LastSync = $_.lastSyncDateTime; Model = $_.model }

            $escrowed = $false
            try {
                $result   = Invoke-MgGraphRequest -Method GET -Uri "$baseUri/deviceManagement/managedDevices/$($_.id)/getFileVaultKey" -OutputType PSObject
                $escrowed = -not [string]::IsNullOrEmpty($result.value)
            } catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
                if ($statusCode -in @(400, 404)) {
                    # 400/404 = no key escrowed for this device (expected)
                    $escrowed = $false
                } elseif ($statusCode -eq 403) {
                    Write-Warning "Permission denied for device $($_.TargetObject). Check PrivilegedOperations.All consent."
                    $escrowed = $false
                } else {
                    Write-Warning "Unexpected error for device $($_.TargetObject): $($_.Exception.Message)"
                    $escrowed = $false
                }
            }
            $script:fileVaultMap[$_.azureADDeviceId] = $escrowed
        }
    Write-Host "  Found $($script:intuneMap.Count) Intune macOS device(s)." -ForegroundColor Cyan
}

function Build-Report {
    Write-Host "Analyzing..." -ForegroundColor Yellow
    $script:report = foreach ($device in $script:devices) {
        $aadId    = $device.deviceId
        $escrowed = $script:fileVaultMap.ContainsKey($aadId) -and $script:fileVaultMap[$aadId]

        [PSCustomObject]@{
            DeviceName        = $device.displayName
            DeviceId          = $aadId
            IntuneDeviceId    = $script:intuneMap[$aadId]?.Id
            Model             = $script:intuneMap[$aadId]?.Model
            EscrowStatus      = if ($escrowed) { "YES" } else { "NO" }
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
    $baseName = "FileVaultEscrow_${tenantId}_${date}"

    $csvPath = Join-Path $reportsDir "$baseName.csv"
    $script:report | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV saved: $csvPath" -ForegroundColor Cyan
}

# ── Execution ─────────────────────────────────────────────────────────────────

$reportsDir = Join-Path $PSScriptRoot "reports"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir | Out-Null }
$transcriptPath = Join-Path $reportsDir "FileVaultEscrow_$(Get-Date -Format 'yyyy-MM-dd_HHmm').log"
Start-Transcript -Path $transcriptPath -Force

try {
    Initialize-MgGraphModule
    Connect-Graph
    Get-MacDevices
    Get-IntuneDeviceInfo
    Build-Report
    Show-Summary
    Export-Report
} finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    Stop-Transcript
}
