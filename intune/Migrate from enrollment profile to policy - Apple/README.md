# Apple ADE Enrollment Migration

Assigns devices to an existing **new Apple ADE enrollment policy**, including
policies with enrollment-time grouping. The script retains its original filename
but now performs assignments rather than only exporting candidates.

1. Connect to Microsoft Graph and select one Apple Business / School token.
2. Select iOS/iPadOS, macOS, tvOS, or visionOS.
3. Choose unassigned devices only, or unassigned devices plus one legacy profile.
4. Select a new enrollment policy for that token and platform.
5. Review the devices and confirm assignment. Requests use batches of serial
   numbers, followed by assignment readback polling and a CSV result report.

Devices assigned to other profiles or new policies, unknown platforms, and
devices deleted from Apple are excluded. All collection pages are read. No
default policy is inferred or changed.

## Run

Use an account with an active Intune license and suitable Intune access.
The script uses interactive sign-in and the delegated Graph permission
`DeviceManagementServiceConfig.ReadWrite.All`, which may require administrator
consent. It automatically installs Microsoft.Graph.Authentication for the current
user from PowerShell Gallery if missing, then imports it before sign-in.
Create the target enrollment policy in Intune before running the script.

```powershell
# Preview the selection without assigning devices.
& '.\Get-AppleEnrollmentMigrationCandidates.ps1' -WhatIf

# Assign after reviewing the confirmation prompt.
& '.\Get-AppleEnrollmentMigrationCandidates.ps1'
```

Sign-in and token, platform, source, and target policy selection are interactive.

`-BatchSize` defaults to 100 and accepts 1-1000. After assignment, the script
polls Intune every five seconds for up to 120 seconds by default. Set
`-VerificationTimeoutSeconds` to change the timeout (0-1800 seconds).
Use 1 when testing on a token with only a single candidate; batch size limits
request size, not the total number of devices migrated. `-Confirm:$false` skips
the final confirmation but does not skip the selection menus.

Reports are written to `reports` beside the script; override with
`-OutputDirectory`. Local reports are also written during `-WhatIf`; no assignment
POSTs are sent. Reports contain serial numbers and tenant identifiers and should
be protected. Q cancels any selection before assignment.

## Assignment API

New enrollment policies are Settings Catalog objects, but Intune also mirrors
them into the selected token's `enrollmentProfiles` collection with `ECV2_` IDs.
The script offers only those mirrored entries for the selected platform as
assignment targets, and excludes them from legacy-source selection. It uses the
full mirrored ID, not the bare Settings Catalog policy GUID:

```http
POST https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/{tokenId}/enrollmentProfiles/{ECV2_mirroredProfileId}/updateDeviceProfileAssignment
Content-Type: application/json

{"deviceIds":["DEVICE_SERIAL_NUMBER"]}
```

Despite the parameter name, `deviceIds` contains **serial numbers**, not Intune,
Entra, or imported-device object IDs. No Entra group assignments are modified.
The mirror behavior is described in the migration walkthrough linked below;
Microsoft's action documentation does not describe that distinction. These beta
APIs may change. Test with a small candidate set before a production migration.

## Results

The CSV is saved before any requests and updated during assignment readback.
`Verified` means the device's requested enrollment profile matches the target
mirror, allowing the API to return either the complete mirrored ID or the same
GUID without a prefix. `Not verified before timeout` means the target was not
visible before the polling deadline; the CSV includes the last observed profile
ID and verification detail to help diagnose a mismatch. Check Intune before
retrying. The timeout does not trigger another assignment request.

If a request fails, subsequent batches are not sent. The affected batch is marked
`Request failed - outcome unverified`, unless readback confirms the target; later
batches remain `Not attempted`. A failed request can have an uncertain outcome,
so inspect Intune and the report before retrying. Already completed batches are
not rolled back. `WhatIf` and `Skipped` mean no requests were sent.

No wipe or re-enrollment is performed. A future enrollment assignment does not
retroactively run Setup Assistant or apply enrollment-time grouping to already
enrolled devices. New enrollment settings generally take effect after a device
is reset and enrolled again. Default policies and legacy profiles are left intact.

## References

- [Apple ADE policy assignment walkthrough and ECV2 mirrors](https://sastu-insights.com/posts/Migrating-from-Apple-Enrollment-Profiles-to-the-Enrollment-Policies/)
- [Graph updateDeviceProfileAssignment action](https://learn.microsoft.com/graph/api/intune-enrollment-enrollmentprofile-updatedeviceprofileassignment?view=graph-rest-beta)
- [New Apple ADE enrollment policies experience](https://techcommunity.microsoft.com/blog/intunecustomersuccess/new-iosipados-visionos-tvos-and-macos-ade-enrollment-policies-experience/4393531)
- [Apple enrollment token resource](https://learn.microsoft.com/graph/api/resources/intune-enrollment-deponboardingsetting?view=graph-rest-beta)
- [Apple device identity resource](https://learn.microsoft.com/graph/api/resources/intune-enrollment-importedappledeviceidentity?view=graph-rest-beta)