<#
.SYNOPSIS
    Exports Intune device management (PowerShell) scripts to the local filesystem.

.DESCRIPTION
    Connects to Microsoft Graph via Microsoft.Graph.Authentication and downloads
    all PowerShell scripts assigned in Intune device management, saving them to a
    per-tenant scripts subfolder. Optionally filter by filename.

.PARAMETER FileName
    Optional. Export only the script matching this exact filename.
    If omitted, all platform scripts are exported.

.EXAMPLE
    .\Get-DeviceManagementScripts.ps1
    Exports all platform scripts.

.EXAMPLE
    .\Get-DeviceManagementScripts.ps1 -FileName "myScript.ps1"
    Exports only the script named myScript.ps1.

.NOTES
    Required Graph API permissions:
      - DeviceManagementScripts.Read.All

    Run once to install the module:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force

    Author:  Simon Pauly Kofoed Mose
    Blog:    https://paulycloud.com
    Version: 2.0 - Rebuilt with functions, transcript logging, Microsoft.Graph.Authentication
             1.0 - Initial release
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$FileName
)

# ── Variables ─────────────────────────────────────────────────────────────────
$baseUri = "https://graph.microsoft.com/beta"
$scopes  = @("DeviceManagementScripts.Read.All")

# ── Functions ─────────────────────────────────────────────────────────────────

function Initialize-MgGraphModule {
    if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Authentication")) {
        Write-Host "Installing Microsoft.Graph.Authentication..." -ForegroundColor Yellow
        Install-Module "Microsoft.Graph.Authentication" -Scope CurrentUser -Force
    }
    Import-Module "Microsoft.Graph.Authentication" -ErrorAction Stop
    Write-Host "Microsoft.Graph.Authentication module loaded." -ForegroundColor Green
}

function Connect-Graph {
    Connect-MgGraph -Scopes $scopes -NoWelcome
    Write-Host "Connected to Microsoft Graph." -ForegroundColor Green
}

function Get-TenantInfo {
    $org = (Invoke-MgGraphRequest -Method GET -Uri "$baseUri/organization?`$select=id,displayName" -OutputType PSObject).value[0]
    $script:tenantId   = $org.id
    $script:tenantName = $org.displayName
    Write-Host "Tenant: $($script:tenantName) ($($script:tenantId))" -ForegroundColor Cyan
}

function Get-ScriptList {
    Write-Host "Fetching platform scripts from Intune..." -ForegroundColor Cyan
    $result = Invoke-MgGraphRequest -Method GET -Uri "$baseUri/deviceManagement/deviceManagementScripts" -OutputType PSObject

    if ($FileName) {
        $script:scriptList = $result.value | Where-Object { $_.fileName -eq $FileName }
        if (-not $script:scriptList) {
            Write-Host "  No script found matching '$FileName'." -ForegroundColor Red
            return
        }
        Write-Host "  Found 1 script matching '$FileName'." -ForegroundColor Cyan
    } else {
        $script:scriptList = $result.value
        Write-Host "  Found $($script:scriptList.Count) script(s)." -ForegroundColor Cyan
    }
}

function Export-Scripts {
    if (-not $script:scriptList) { return }

    $scriptsDir = Join-Path $PSScriptRoot "reports" $script:tenantName
    if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }

    $exported = 0
    foreach ($entry in $script:scriptList) {
        try {
            $detail  = Invoke-MgGraphRequest -Method GET -Uri "$baseUri/deviceManagement/deviceManagementScripts/$($entry.id)" -OutputType PSObject
            $content = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($detail.scriptContent))
            $outPath = Join-Path $scriptsDir $detail.fileName
            $content | Out-File -Encoding ASCII -FilePath $outPath
            Write-Host "  Exported: $($detail.fileName)" -ForegroundColor Gray
            $exported++
        } catch {
            Write-Host "  Failed:   $($entry.fileName) - $_" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "Exported $exported script(s) to: $scriptsDir" -ForegroundColor Green
}

# ── Execution ─────────────────────────────────────────────────────────────────

$reportsDir = Join-Path $PSScriptRoot "reports"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir | Out-Null }
$transcriptPath = Join-Path $reportsDir "DeviceManagementScripts_$(Get-Date -Format 'yyyy-MM-dd_HHmm').log"
Start-Transcript -Path $transcriptPath -Force

try {
    Initialize-MgGraphModule
    Connect-Graph
    Get-TenantInfo
    Get-ScriptList
    Export-Scripts
} finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    Stop-Transcript
}