<#
.SYNOPSIS
    Deletes the Windows Hello container for the current user.

.DESCRIPTION
    Runs certutil -deleteHelloContainer to remove the Windows Hello for Business container.
    Must be run in the logged-on user's context.

    Exit codes:
    - 0: Windows Hello container deleted successfully
    - 1: Failed to delete Windows Hello container

.NOTES
    Author:  Simon Pauly Kofoed Mose
    Blog:    https://paulycloud.com
    Version: 1.0 - Initial release
#>

#region Detection

$result = certutil -deleteHelloContainer 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "COMPLIANT | Hello Container: Deleted | User: $env:USERNAME"
    exit 0
} else {
    Write-Host "NON-COMPLIANT | Hello Container: Failed to delete | User: $env:USERNAME | Exit Code: $LASTEXITCODE"
    exit 1
}

#endregion
