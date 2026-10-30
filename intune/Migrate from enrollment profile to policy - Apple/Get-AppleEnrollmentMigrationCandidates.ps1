<#
.SYNOPSIS
    Assigns Apple ADE devices to a new enrollment policy.

.DESCRIPTION
    Connects to Intune through Microsoft.Graph.Authentication, lists Apple
    enrollment tokens, and prompts for one platform. Includes devices without
    an assigned profile and, optionally, devices assigned to one selected legacy
    profile. Confirm that the source profile is under Profiles, not Enrollment
    policies, in the Intune admin center.

    Prompts for a new enrollment policy mirrored into the token's enrollmentProfiles
    collection with an ECV2_ ID. Assigns candidate serial numbers through that
    mirror's updateDeviceProfileAssignment action, then reads back assignments.
    Existing assignments to other new policies are excluded from migration.

    Uses interactive delegated login and requires the following Graph permission:
        DeviceManagementServiceConfig.ReadWrite.All
    An active Intune license and appropriate Intune access are also required.

    Install the authentication module before running:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

    Reports contain device serial numbers; store them securely.

.PARAMETER TenantId
    Optional tenant ID or verified domain used for interactive sign-in.

.PARAMETER OutputDirectory
    Destination for the assignment CSV. Defaults to reports beside this script.

.PARAMETER BatchSize
    Maximum serial numbers per assignment request. Defaults to 100.

.PARAMETER VerificationTimeoutSeconds
    Maximum time to poll Intune for assignment readback. Defaults to 120 seconds.

.EXAMPLE
    .\Get-AppleEnrollmentMigrationCandidates.ps1 -TenantId contoso.onmicrosoft.com -WhatIf

.EXAMPLE
    .\Get-AppleEnrollmentMigrationCandidates.ps1 -TenantId contoso.onmicrosoft.com

.NOTES
    Uses Microsoft Graph beta APIs, which are subject to change.
    This script does not wipe, retire, release, or re-enroll devices, change
    default profiles, or add existing devices to enrollment-time groups.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$TenantId,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'reports'),
    [ValidateRange(1, 1000)][int]$BatchSize = 100,
    [ValidateRange(0, 1800)][int]$VerificationTimeoutSeconds = 120
)

function Get-GraphCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)

    $nextUri = $Uri
    do {
        $parsedUri = [uri]$nextUri
        if ($parsedUri.Scheme -ne 'https' -or $parsedUri.Host -ne 'graph.microsoft.com') {
            throw 'Refusing a collection URL outside Microsoft Graph.'
        }

        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri -OutputType PSObject -ErrorAction Stop
        if ($null -eq $response -or $null -eq $response.PSObject.Properties['value']) {
            throw "Graph did not return a collection for $nextUri. No candidate report was generated."
        }
        foreach ($item in $response.value) {
            $item
        }
        $nextUri = $response.'@odata.nextLink'
    } while (-not [string]::IsNullOrWhiteSpace($nextUri))
}

function Select-MenuItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Label
    )

    if ($Items.Count -eq 0) {
        throw "No choices available: $Title"
    }

    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Write-Host ('  {0}. {1}' -f ($index + 1), (& $Label $Items[$index]))
    }
    Write-Host '  Q. Cancel'

    while ($true) {
        $answer = Read-Host 'Select one number'
        if ($answer -eq 'q') {
            throw [System.OperationCanceledException]::new('Selection canceled. No Intune changes were made.')
        }
        $selection = 0
        if ([int]::TryParse($answer, [ref]$selection) -and $selection -ge 1 -and $selection -le $Items.Count) {
            return $Items[$selection - 1]
        }
        Write-Warning 'Enter a number from the list, or Q to cancel.'
    }
}

function Test-SameEnrollmentProfileId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FirstId,
        [Parameter(Mandatory)][string]$SecondId
    )

    if ($FirstId -eq $SecondId) {
        return $true
    }

    $firstSuffix = ($FirstId -split '_')[-1]
    $secondSuffix = ($SecondId -split '_')[-1]
    $firstGuid = [guid]::Empty
    $secondGuid = [guid]::Empty
    return [guid]::TryParse($firstSuffix, [ref]$firstGuid) -and
        [guid]::TryParse($secondSuffix, [ref]$secondGuid) -and
        $firstGuid -eq $secondGuid
}

function Get-MigrationCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory)][string]$Platform,
        [string]$LegacyProfileId
    )

    if ($LegacyProfileId -like 'ECV2_*') {
        throw 'A new enrollment policy cannot be selected as the legacy migration source.'
    }
    foreach ($device in $Devices) {
        if ($device.isDeleted -eq $true -or $device.platform -ne $Platform) {
            continue
        }
        if ($null -eq $device.PSObject.Properties['requestedEnrollmentProfileId']) {
            throw "Device $($device.id) is missing requestedEnrollmentProfileId; eligibility cannot be determined safely."
        }
        if ([string]::IsNullOrWhiteSpace([string]$device.id) -or
            [string]::IsNullOrWhiteSpace([string]$device.serialNumber)) {
            throw 'A matching device is missing its identity or serial number; review the Graph response.'
        }

        $assignedProfileId = [string]$device.requestedEnrollmentProfileId
        if ($assignedProfileId -like 'ECV2_*') {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($assignedProfileId) -or
            (-not [string]::IsNullOrWhiteSpace($LegacyProfileId) -and
                (Test-SameEnrollmentProfileId -FirstId $assignedProfileId -SecondId $LegacyProfileId))) {
            $device
        }
    }
}

function Set-AppleEnrollmentPolicyAssignment {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$TokenId,
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Devices,
        [ValidateRange(1, 1000)][int]$BatchSize = 100
    )

    if ($Policy.id -notlike 'ECV2_*') {
        throw 'The target must be a new enrollment policy with an ECV2_ mirrored profile ID.'
    }
    $results = @(foreach ($device in $Devices) {
        if ([string]::IsNullOrWhiteSpace([string]$device.serialNumber)) {
            throw 'Cannot assign a device without a serial number.'
        }
        [pscustomobject]@{
            AppleDeviceIdentityId = $device.id
            SerialNumber = $device.serialNumber
            AssignmentStatus = 'Not attempted'
            ErrorMessage = ''
        }
    })
    if ($results.Count -eq 0) {
        return
    }

    $target = "Policy '$($Policy.displayName)' ($($Policy.id)), token $TokenId, $($results.Count) device(s)"
    if (-not $PSCmdlet.ShouldProcess($target, 'Assign Apple enrollment policy for next enrollment')) {
        foreach ($result in $results) {
            $result.AssignmentStatus = if ($WhatIfPreference) { 'WhatIf' } else { 'Skipped' }
        }
        return $results
    }

    $uri = 'https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/{0}/enrollmentProfiles/{1}/updateDeviceProfileAssignment' -f
        [uri]::EscapeDataString($TokenId), [uri]::EscapeDataString($Policy.id)
    for ($offset = 0; $offset -lt $results.Count; $offset += $BatchSize) {
        $lastIndex = [Math]::Min($offset + $BatchSize, $results.Count) - 1
        $batch = @($results[$offset..$lastIndex])
        $body = @{ deviceIds = @($batch.SerialNumber | Select-Object -Unique) } | ConvertTo-Json -Depth 3
        try {
            Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
            foreach ($result in $batch) {
                $result.AssignmentStatus = 'Submitted - awaiting verification'
            }
        } catch {
            foreach ($result in $batch) {
                $result.AssignmentStatus = 'Request failed - outcome unverified'
                $result.ErrorMessage = $_.Exception.Message
            }
            Write-Warning "Assignment request failed; remaining batches will not be sent. $($_.Exception.Message)"
            break
        }
    }
    $results
}

function Wait-AppleEnrollmentAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TokenUri,
        [Parameter(Mandatory)][string]$PolicyId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Report,
        [Parameter(Mandatory)][string]$ReportPath,
        [ValidateRange(0, 1800)][int]$TimeoutSeconds = 120,
        [ValidateRange(0, 300)][int]$PollIntervalSeconds = 5
    )

    $pendingStatuses = @('Submitted - awaiting verification', 'Request failed - outcome unverified')
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $successfulReadback = $false
    $lastReadError = $null
    $firstRead = $true

    do {
        try {
            $currentAssignments = @{}
            foreach ($device in (Get-GraphCollection -Uri "$TokenUri/importedAppleDeviceIdentities")) {
                $currentAssignments[$device.id] = $device.requestedEnrollmentProfileId
            }
            $successfulReadback = $true
            $lastReadError = $null

            foreach ($row in $Report) {
                if ($row.AssignmentStatus -in $pendingStatuses) {
                    $observedProfileId = [string]$currentAssignments[$row.AppleDeviceIdentityId]
                    $row | Add-Member -NotePropertyName ObservedProfileId -NotePropertyValue $observedProfileId -Force
                    if (-not [string]::IsNullOrWhiteSpace($observedProfileId) -and
                        (Test-SameEnrollmentProfileId -FirstId $observedProfileId -SecondId $PolicyId)) {
                        $row.AssignmentStatus = 'Verified'
                        $row.VerificationError = ''
                    }
                }
            }
            $Report | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
        } catch {
            $lastReadError = $_.Exception.Message
            Write-Warning "Could not read back Apple device assignments yet: $lastReadError"
        }

        $pending = @($Report | Where-Object { $_.AssignmentStatus -in $pendingStatuses })
        if ($pending.Count -eq 0 -or $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            break
        }

        if ($PollIntervalSeconds -gt 0) {
            $remainingSeconds = [Math]::Max(0, $TimeoutSeconds - $stopwatch.Elapsed.TotalSeconds)
            $sleepSeconds = [Math]::Min($PollIntervalSeconds, [Math]::Ceiling($remainingSeconds))
            if ($sleepSeconds -gt 0) {
                Start-Sleep -Seconds $sleepSeconds
            }
        }
        $firstRead = $false
    } while ($firstRead -or $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    foreach ($row in $Report) {
        if ($row.AssignmentStatus -in $pendingStatuses) {
            $row.AssignmentStatus = 'Not verified before timeout'
            if ($lastReadError) {
                $row.VerificationError = $lastReadError
            } elseif (-not $successfulReadback) {
                $row.VerificationError = 'No successful assignment readback was received.'
            } else {
                $observedProfileId = if ([string]::IsNullOrWhiteSpace([string]$row.ObservedProfileId)) {
                    '<none returned>'
                } else {
                    $row.ObservedProfileId
                }
                $row.VerificationError = "Target policy '$PolicyId' was not visible after $TimeoutSeconds second(s). Last observed profile ID: '$observedProfileId'."
            }
        }
    }
    $Report | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
}

function Invoke-AppleEnrollmentCandidateExport {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$TenantId,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateRange(1, 1000)][int]$BatchSize = 100,
        [ValidateRange(0, 1800)][int]$VerificationTimeoutSeconds = 120
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host 'Installing Microsoft.Graph.Authentication for the current user...' -ForegroundColor Cyan
        Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $connectionParameters = @{
        Scopes = @('DeviceManagementServiceConfig.ReadWrite.All')
        ContextScope = 'Process'
        NoWelcome = $true
        ErrorAction = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectionParameters.TenantId = $TenantId
    }

    $connected = $false
    try {
        Connect-MgGraph @connectionParameters | Out-Null
        $connected = $true
        $context = Get-MgContext
        Write-Host "Connected to tenant $($context.TenantId) as $($context.Account)." -ForegroundColor Green

        $baseUri = 'https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings'
        $tokens = @(Get-GraphCollection -Uri $baseUri | Sort-Object tokenName, id)
        $token = Select-MenuItem -Title 'Apple Business / School enrollment token' -Items $tokens -Label {
            param($item)
            '{0} | Apple ID: {1} | Expires: {2} | ID: {3}' -f $item.tokenName, $item.appleIdentifier, $item.tokenExpirationDateTime, $item.id
        }
        $tokenUri = "$baseUri/$([uri]::EscapeDataString($token.id))"

        $platforms = @(
            [pscustomobject]@{ Name = 'iOS/iPadOS'; Value = 'ios'; ProfileType = '#microsoft.graph.depIOSEnrollmentProfile' }
            [pscustomobject]@{ Name = 'macOS'; Value = 'macOS'; ProfileType = '#microsoft.graph.depMacOSEnrollmentProfile' }
            [pscustomobject]@{ Name = 'tvOS'; Value = 'tvos'; ProfileType = '#microsoft.graph.depTvOSEnrollmentProfile' }
            [pscustomobject]@{ Name = 'visionOS'; Value = 'visionOS'; ProfileType = '#microsoft.graph.depVisionOSEnrollmentProfile' }
        )
        $platform = Select-MenuItem -Title 'Device platform' -Items $platforms -Label { param($item) $item.Name }

        $profiles = @(Get-GraphCollection -Uri "$tokenUri/enrollmentProfiles" |
            Where-Object { $_.'@odata.type' -eq $platform.ProfileType } | Sort-Object displayName, id)
        $policies = @($profiles | Where-Object { $_.id -like 'ECV2_*' })
        if ($policies.Count -eq 0) {
            throw "No new $($platform.Name) enrollment policies were found for this token. Create one under Enrollment policies in Intune first."
        }
        $sources = @([pscustomobject]@{ Name = 'No profile only'; Id = ''; ProfileName = '' })
        foreach ($enrollmentProfile in ($profiles | Where-Object { $_.id -notlike 'ECV2_*' })) {
            $sources += [pscustomobject]@{
            Name = "No profile OR legacy profile: $($enrollmentProfile.displayName) | ID: $($enrollmentProfile.id)"
            Id = $enrollmentProfile.id
            ProfileName = $enrollmentProfile.displayName
            }
        }
        $source = Select-MenuItem -Title 'Migration source' -Items $sources -Label { param($item) $item.Name }

        Write-Host 'Reading all pages of devices for the selected token...' -ForegroundColor Cyan
        $devices = @(Get-GraphCollection -Uri "$tokenUri/importedAppleDeviceIdentities")
        $candidates = @(Get-MigrationCandidate -Devices $devices -Platform $platform.Value -LegacyProfileId $source.Id |
            Sort-Object serialNumber, id)
        Write-Host "Found $($candidates.Count) candidate(s) out of $($devices.Count) token device(s)." -ForegroundColor Cyan
        if ($candidates.Count -eq 0) {
            $platformDevices = @($devices | Where-Object {
                $_.platform -eq $platform.Value -and $_.isDeleted -ne $true
            })
            Write-Warning "No candidates matched. Non-deleted devices for $($platform.Name): $($platformDevices.Count). Selected legacy profile ID: '$($source.Id)'."
            $profileCounts = @($platformDevices | Group-Object {
                if ([string]::IsNullOrWhiteSpace([string]$_.requestedEnrollmentProfileId)) {
                    '<unassigned>'
                } else {
                    [string]$_.requestedEnrollmentProfileId
                }
            } | Sort-Object Count -Descending | Select-Object -First 10)
            if ($profileCounts.Count -gt 0) {
                Write-Host 'Most common requested enrollment profile IDs for this platform:' -ForegroundColor Yellow
                $profileCounts | ForEach-Object {
                    Write-Host ('  {0} device(s): {1}' -f $_.Count, $_.Name)
                }
            }
            return
        }

        $policy = Select-MenuItem -Title 'New enrollment policy to assign' -Items $policies -Label {
            param($item)
            '{0} | ID: {1}' -f $item.displayName, $item.id
        }
        $report = foreach ($device in $candidates) {
            $noProfile = [string]::IsNullOrWhiteSpace([string]$device.requestedEnrollmentProfileId)
            [pscustomobject]@{
                TenantId = $context.TenantId
                TokenName = $token.tokenName
                TokenId = $token.id
                Platform = $platform.Name
                SerialNumber = $device.serialNumber
                AppleDeviceIdentityId = $device.id
                EnrollmentState = $device.enrollmentState
                SourceProfileId = $device.requestedEnrollmentProfileId
                SourceProfileName = if ($noProfile) { '' } else { $source.ProfileName }
                CandidateReason = if ($noProfile) { 'No profile' } else { 'Selected legacy profile' }
                TargetPolicyName = $policy.displayName
                TargetPolicyId = $policy.id
                ObservedProfileId = ''
                AssignmentStatus = 'Not attempted'
                ErrorMessage = ''
                VerificationError = ''
            }
        }
        $report | Select-Object SerialNumber, Platform, EnrollmentState, CandidateReason | Format-Table -AutoSize | Out-Host
        New-Item -ItemType Directory -Path $OutputDirectory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop | Out-Null
        $fileName = 'AppleEnrollmentAssignment_{0}_{1}_{2}.csv' -f $context.TenantId, $platform.Value, (Get-Date -Format 'yyyy-MM-dd_HHmmss_fff')
        $reportPath = Join-Path $OutputDirectory $fileName
        $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
        Write-Host "Assignment report: $reportPath" -ForegroundColor Cyan
        Write-Warning 'Assignment changes the next enrollment. This does not wipe devices or retroactively apply enrollment-time grouping.'

        if ($PSCmdlet.ShouldProcess("$($candidates.Count) $($platform.Name) devices on token '$($token.tokenName)'", "Assign new enrollment policy '$($policy.displayName)'")) {
            $results = @(Set-AppleEnrollmentPolicyAssignment -TokenId $token.id -Policy $policy -Devices $candidates -BatchSize $BatchSize -Confirm:$false)
        } else {
            $results = @()
            foreach ($row in $report) {
                $row.AssignmentStatus = if ($WhatIfPreference) { 'WhatIf' } else { 'Skipped' }
            }
        }

        foreach ($result in $results) {
            $row = $report | Where-Object { $_.AppleDeviceIdentityId -eq $result.AppleDeviceIdentityId }
            $row.AssignmentStatus = $result.AssignmentStatus
            $row.ErrorMessage = $result.ErrorMessage
        }
        $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false -ErrorAction Stop

        if (@($report | Where-Object { $_.AssignmentStatus -in @('Submitted - awaiting verification', 'Request failed - outcome unverified') }).Count -gt 0) {
            Write-Host "Verifying assignment readback for up to $VerificationTimeoutSeconds second(s)..." -ForegroundColor Cyan
            Wait-AppleEnrollmentAssignment -TokenUri $tokenUri -PolicyId $policy.id -Report $report -ReportPath $reportPath -TimeoutSeconds $VerificationTimeoutSeconds
        }
        $report | Group-Object AssignmentStatus | Select-Object Name, Count | Format-Table -AutoSize | Out-Host
        if (@($report | Where-Object { $_.AssignmentStatus -notin @('Verified', 'WhatIf', 'Skipped') }).Count -gt 0) {
            Write-Warning "Some assignments are unverified or not attempted. Review $reportPath and check Intune before rerunning."
        }
    } finally {
        if ($connected) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $executionParameters = @{} + $PSBoundParameters
    $executionParameters.OutputDirectory = $OutputDirectory
    Invoke-AppleEnrollmentCandidateExport @executionParameters
}