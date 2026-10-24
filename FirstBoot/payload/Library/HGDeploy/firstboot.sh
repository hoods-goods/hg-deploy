#!/bin/bash
# HG Deploy first boot. Runs once, as root, on the newly installed macOS.
# Reads the settings HG Deploy saved in NVRAM, deletes them right away (they
# can hold a password), applies them, removes itself, and restarts if it
# created an account.

LOG=/var/log/hgdeploy.log
exec >>"$LOG" 2>&1
echo "=== $(/bin/date) HG Deploy first boot on macOS $(/usr/bin/sw_vers -productVersion) ==="

NV=com.hgcellular.deploy
PLIST=/Library/LaunchDaemons/com.hgcellular.deploy.firstboot.plist

cleanup() {
    /bin/rm -f "$PLIST"
    /bin/rm -rf /Library/HGDeploy
}

SKIPPED_MARKER=/Library/HGDeploy/.skipped-setup-assistant

# If Setup Assistant was skipped for an account but no account got made, bring
# Setup Assistant back so the Mac is never left at a login nobody can use.
undo_skip_if_no_account() {
    [ -f "$SKIPPED_MARKER" ] || return 0
    local users
    users=$(/usr/bin/dscl . -list /Users UniqueID 2>/dev/null | /usr/bin/awk '$2 >= 501 && $2 < 60000 {print $1}')
    if [ -z "$users" ]; then
        echo "No account was created: removing .AppleSetupDone so Setup Assistant runs."
        /bin/rm -f /private/var/db/.AppleSetupDone
        NEED_RESTART=1
    fi
}

# Settings saved by the package (survive NVRAM resets), else NVRAM.
raw=""
[ -s /Library/HGDeploy/settings ] && raw=$(/bin/cat /Library/HGDeploy/settings)
[ -z "$raw" ] && raw=$(/usr/sbin/nvram "$NV" 2>/dev/null | /usr/bin/sed -E "s/^${NV}[[:space:]]+//")
/usr/sbin/nvram -d "$NV" 2>/dev/null
if [ -z "$raw" ]; then
    echo "No settings found (file or NVRAM); nothing to do."
    NEED_RESTART=0
    undo_skip_if_no_account
    cleanup
    [ "$NEED_RESTART" = 1 ] && /sbin/shutdown -r now
    exit 0
fi
cfg=$(printf '%s' "$raw" | /usr/bin/base64 -D 2>/dev/null)

# val KEY -> decoded value (each value is base64 so any character is safe)
val() {
    printf '%s\n' "$cfg" | /usr/bin/awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' \
        | /usr/bin/base64 -D 2>/dev/null
}

# Wait until Directory Services is up.
for _ in $(/usr/bin/seq 1 60); do
    /usr/bin/dscl . -read /Users/root >/dev/null 2>&1 && break
    /bin/sleep 2
done

NEED_RESTART=0
REFRESH_LOGIN=0

# --- Computer name ---
CN=$(val COMPUTERNAME)
if [ -n "$CN" ]; then
    LHN=$(printf '%s' "$CN" | /usr/bin/tr -cs 'A-Za-z0-9-' '-' | /usr/bin/sed -E 's/^-+//; s/-+$//' | /usr/bin/cut -c1-63)
    /usr/sbin/scutil --set ComputerName "$CN"
    [ -n "$LHN" ] && /usr/sbin/scutil --set LocalHostName "$LHN" && /usr/sbin/scutil --set HostName "$LHN"
    /usr/bin/defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$(printf '%s' "$LHN" | /usr/bin/cut -c1-15)"
    echo "Computer name: $CN ($LHN)"
fi

# --- Account ---
skip_setup_screens() {
    # Marks the per-user Setup Assistant screens (iCloud, Siri, Screen Time,
    # appearance...) as seen so the first login goes straight to the desktop.
    local home="$1" user="$2"
    local prefs="$home/Library/Preferences/com.apple.SetupAssistant"
    local os build
    os=$(/usr/bin/sw_vers -productVersion)
    build=$(/usr/bin/sw_vers -buildVersion)
    /bin/mkdir -p "$home/Library/Preferences"
    local k
    for k in DidSeeCloudSetup DidSeeSiriSetup DidSeePrivacy DidSeeTouchIDSetup DidSeeScreenTime \
             DidSeeAppearanceSetup DidSeeTrueTone DidSeeTrueTonePrivacy DidSeeApplePaySetup DidSeeAvatarSetup \
             DidSeeSyncSetup DidSeeSyncSetup2 DidSeeiCloudLoginForStorageServices DidSeeActivationLock \
             DidSeeAccessibility DidSeeAppStore DidSeeTermsOfAddress DidSeeIntelligence DidSeeLockdownMode \
             DidSeeWallpaper DidSeeUpdateCompleted; do
        /usr/bin/defaults write "$prefs" "$k" -bool true
    done
    for k in LastSeenCloudProductVersion LastSeeniCloudStorageServicesProductVersion LastSeenSyncProductVersion \
             LastSeenDiagnosticsProductVersion LastSeenSiriProductVersion; do
        /usr/bin/defaults write "$prefs" "$k" -string "$os"
    done
    /usr/bin/defaults write "$prefs" LastSeenBuddyBuildVersion -string "$build"
    /usr/sbin/chown -R "$user":staff "$home/Library"
}

write_kcpassword() {
    # /etc/kcpassword: the password XORed with Apple's fixed key, NUL-terminated
    # and padded to a multiple of 12 bytes. Needed for automatic login.
    local key=(125 137 82 35 210 188 221 234 163 185 31)
    local bytes=($(printf '%s' "$1" | /usr/bin/od -An -v -tu1))
    bytes+=(0)
    while [ $(( ${#bytes[@]} % 12 )) -ne 0 ]; do bytes+=(0); done
    : > /etc/kcpassword
    local i
    for i in "${!bytes[@]}"; do
        printf "\\$(printf '%03o' $(( bytes[i] ^ key[i % 11] )))" >> /etc/kcpassword
    done
    /bin/chmod 600 /etc/kcpassword
    /usr/sbin/chown root:wheel /etc/kcpassword
}

if [ "$(val CREATE_USER)" = 1 ]; then
    SN=$(val SHORTNAME)
    FN=$(val FULLNAME)
    PW=$(val PASSWORD)
    if [ -z "$SN" ]; then
        echo "No account name; skipping account."
    elif /usr/bin/id "$SN" >/dev/null 2>&1; then
        echo "Account $SN already exists."
    else
        args=(-addUser "$SN" -fullName "$FN")
        [ "$(val ADMIN)" = 1 ] && args+=(-admin)
        if [ -n "$PW" ]; then
            args+=(-password "$PW")
        else
            args+=(-password "hgdeploy-temporary")
        fi
        /usr/sbin/sysadminctl "${args[@]}" 2>&1 | /usr/bin/grep -vi password
        if ! /usr/bin/id "$SN" >/dev/null 2>&1; then
            echo "sysadminctl didn't create $SN; trying dscl."
            uid=501
            while /usr/bin/dscl . -search /Users UniqueID "$uid" | /usr/bin/grep -q .; do uid=$((uid + 1)); done
            /usr/bin/dscl . -create "/Users/$SN"
            /usr/bin/dscl . -create "/Users/$SN" RealName "$FN"
            /usr/bin/dscl . -create "/Users/$SN" UniqueID "$uid"
            /usr/bin/dscl . -create "/Users/$SN" PrimaryGroupID 20
            /usr/bin/dscl . -create "/Users/$SN" UserShell /bin/zsh
            /usr/bin/dscl . -create "/Users/$SN" NFSHomeDirectory "/Users/$SN"
            /usr/bin/dscl . -passwd "/Users/$SN" "${PW:-hgdeploy-temporary}"
            [ "$(val ADMIN)" = 1 ] && /usr/sbin/dseditgroup -o edit -a "$SN" -t user admin
        fi
        [ -z "$PW" ] && /usr/bin/dscl . -passwd "/Users/$SN" ""
        echo "Created account $SN ($FN), admin=$(val ADMIN)"
    fi
    /usr/sbin/createhomedir -c -u "$SN" >/dev/null 2>&1
    HOME_DIR=$(/usr/bin/dscl . -read "/Users/$SN" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
    if [ -d "$HOME_DIR" ]; then
        skip_setup_screens "$HOME_DIR" "$SN"
        # The whole home folder must belong to the user, or macOS can't create
        # the login keychain at first login ("keychain could not be created").
        /usr/sbin/chown -R "$SN":staff "$HOME_DIR" 2>/dev/null
        echo "Home folder $HOME_DIR owned by $SN"
    else
        echo "Home folder for $SN will be created at first login"
    fi
    /usr/bin/touch /private/var/db/.AppleSetupDone

    if [ "$(val AUTOLOGIN)" = 1 ]; then
        write_kcpassword "$PW"
        /usr/bin/defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$SN"
        echo "Automatic login on for $SN"
    fi
    REFRESH_LOGIN=1
fi

# --- Remote Login ---
if [ "$(val SSH)" = 1 ]; then
    /usr/sbin/systemsetup -setremotelogin on >/dev/null 2>&1
    /bin/launchctl enable system/com.openssh.sshd 2>/dev/null
    /bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
        || /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null
    echo "Remote Login turned on"
fi

undo_skip_if_no_account

cfg=""
PW=""
raw=""
cleanup
echo "HG Deploy first boot finished."
if [ "$NEED_RESTART" = 1 ]; then
    # Only when no account could be made: bring Setup Assistant back.
    echo "Restarting into Setup Assistant."
    /sbin/shutdown -r now
elif [ "$REFRESH_LOGIN" = 1 ]; then
    # Never restart under someone: a restart during the first login breaks the
    # new account's keychain. Refresh the login window only if nobody's logged
    # in (that also starts automatic login).
    console=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)
    if [ -z "$console" ] || [ "$console" = root ] || [ "$console" = _mbsetupuser ]; then
        echo "Refreshing the login window to show the new account."
        /usr/bin/killall loginwindow 2>/dev/null
    else
        echo "$console is already logged in; leaving the session alone."
    fi
fi
exit 0
