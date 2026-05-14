#!/bin/zsh

#set -x

############################################################################################
##
## remediateFileVaultEscrow.zsh
##
## Remediates macOS devices where FileVault is enabled but the recovery key
## has never been escrowed to Intune. Uses Escrow Buddy (by Netflix/macadmins)
## to generate and escrow a new key at the next user login.
##
## https://github.com/macadmins/escrow-buddy
##
## Prerequisites:
##   - FileVault must already be enabled on the device
##   - The Intune FileVault configuration profile (with FDERecoveryKeyEscrow) must be assigned
##
## Designed to run as root via Microsoft Intune shell script deployment.
##
## What this script does:
##   1. Verifies FileVault is enabled
##   2. Verifies the MDM escrow profile is present
##   3. Downloads and installs Escrow Buddy if not already present
##   4. Sets GenerateNewKey flag to trigger key escrow at next login
##
## Logging: /Library/Logs/Intune/RemediateFileVaultEscrow.log
##
## Author:  Simon Pauly Kofoed Mose
## Blog:    https://paulycloud.com
## Version: 2.0 - Replaced fdesetup approach with Escrow Buddy
##          1.0 - Initial release
##
############################################################################################

## Define variables
appname="RemediateFileVaultEscrow"
logandmetadir="/Library/Logs/Intune"
logfile="$logandmetadir/$appname.log"

## Escrow Buddy
escrowBuddyPlugin="/Library/Security/SecurityAgentPlugins/Escrow Buddy.bundle"
escrowBuddyPkg="https://github.com/macadmins/escrow-buddy/releases/download/v1.0.0/Escrow.Buddy-1.0.0.pkg"
escrowBuddyPlist="/Library/Preferences/com.netflix.Escrow-Buddy.plist"

## Create log directory if needed
if [ ! -d "$logandmetadir" ]; then
    mkdir -p "$logandmetadir"
fi

############################################################################################
# Functions
############################################################################################

log () {
    local msg="$(date) | $*"
    echo "$msg"
    echo "$msg" >> "$logfile"
}

downloadFile () {
    local url="$1"
    local dest="$2"
    local maxAttempts=3
    local attempt=1
    while [ $attempt -le $maxAttempts ]; do
        log "Downloading [$url] (attempt $attempt of $maxAttempts)"
        if curl -f -s -L --connect-timeout 30 -o "$dest" "$url"; then
            log "Download successful"
            return 0
        fi
        log "Download attempt $attempt of $maxAttempts failed"
        attempt=$((attempt + 1))
        [ $attempt -le $maxAttempts ] && sleep 10
    done
    log "Download failed after $maxAttempts attempts"
    return 1
}

############################################################################################
# Begin Script Body
############################################################################################

log "Starting $appname"

##
## 1. Check if FileVault is enabled
##
fvStatus=$(fdesetup status)
if ! echo "$fvStatus" | grep -q "FileVault is On"; then
    log "FileVault is not enabled. Nothing to remediate."
    log "Status: $fvStatus"
    exit 0
fi

log "FileVault is enabled"

##
## 2. Check if the MDM escrow profile is present
##
if ! profiles show -all 2>/dev/null | grep -q "com.apple.security.FDERecoveryKeyEscrow"; then
    log "No FDERecoveryKeyEscrow profile found. Assign the Intune FileVault policy first."
    exit 1
fi

log "MDM escrow profile is present"

##
## 3. Install Escrow Buddy if not already present
##
if [ -d "$escrowBuddyPlugin" ]; then
    log "Escrow Buddy already installed at [$escrowBuddyPlugin]"
else
    log "Escrow Buddy not found, downloading and installing..."
    tmpPkg=$(mktemp /tmp/escrow_buddy_XXXXX.pkg)
    if ! downloadFile "$escrowBuddyPkg" "$tmpPkg"; then
        log "Failed to download Escrow Buddy. Exiting."
        rm -f "$tmpPkg"
        exit 1
    fi
    if installer -pkg "$tmpPkg" -target /; then
        log "Escrow Buddy installed successfully"
    else
        log "Failed to install Escrow Buddy. Exiting."
        rm -f "$tmpPkg"
        exit 1
    fi
    rm -f "$tmpPkg"
fi

##
## 4. Set GenerateNewKey flag
##    At the next user login, Escrow Buddy intercepts the login authorization
##    and triggers a new personal recovery key generation + escrow
##
log "Setting GenerateNewKey flag..."
defaults write "$escrowBuddyPlist" GenerateNewKey -bool true

if defaults read "$escrowBuddyPlist" GenerateNewKey 2>/dev/null | grep -q "1"; then
    log "GenerateNewKey flag set successfully"
    log "A new recovery key will be generated and escrowed at the next user login"
else
    log "Failed to set GenerateNewKey flag"
    exit 1
fi

log "$appname completed"
