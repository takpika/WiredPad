#!/bin/zsh
# Sets up sudo to ask the iPad for Touch ID or Face ID before the Mac's own Touch ID and password.
# WiredPad runs it from its settings; it also works by hand:
#
#   sudo PAM/install.sh            build and install the module, the key, and the PAM line
#   sudo PAM/install.sh uninstall  take them all out again
#
# Options: --user NAME for whom (default: whoever ran sudo), --module PATH to install a module
# already built, as WiredPad does with the one in its bundle.
#
# Set up the keys in WiredPad's Diagnostics & Settings first: this copies the public key the app
# wrote to ~/.wiredpad/sudo.pub into a place only root can change, which is what the module trusts.
set -euo pipefail

# Root's alone, like every folder above: a folder the user could change, such as /usr/local/lib
# with Homebrew, would let any of their programs swap in a module that sudo runs as root.
base=/Library/WiredPad
module=$base/pam_wiredpad.so
keys=$base/keys
pam=/etc/pam.d/sudo_local
# Where the first version put them, removed on install and uninstall.
old_module=/usr/local/lib/pam/pam_wiredpad.so
old_keys=/usr/local/etc/wiredpad
line="auth       sufficient     $module"

action=install
user=${SUDO_USER:-}
prebuilt=
while (( $# )); do
  case $1 in
    install|uninstall) action=$1 ;;
    --user) user=$2; shift ;;
    --module) prebuilt=$2; shift ;;
    *) print -u2 "Unknown option $1"; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { print -u2 "Run with sudo."; exit 1; }
[[ -n $user && $user != root && $user != */* ]] || { print -u2 "Run with sudo from your own account, or give --user."; exit 1; }

remove_lines() {
  [[ -f $pam ]] || return 0
  grep -vF pam_wiredpad.so $pam > $pam.wiredpad || true
  cat $pam.wiredpad > $pam && rm $pam.wiredpad
}

remove_old() {
  rm -f $old_module $old_keys/$user.pub
  rmdir ${old_module:h} $old_keys 2>/dev/null || true
}

if [[ $action == uninstall ]]; then
  remove_lines
  remove_old
  rm -f $keys/$user.pub
  # The module stays while another user still has a key.
  if [[ -z $(ls $keys 2>/dev/null) ]]; then rm -rf $base; fi
  print "Removed. sudo uses Touch ID and the password as before."
  exit 0
fi

home=$(dscl . -read /Users/$user NFSHomeDirectory | awk '{print $2}')
source_key=$home/.wiredpad/sudo.pub
[[ -s $source_key ]] || { print -u2 "No $source_key: set up the keys in WiredPad first."; exit 1; }

# Built, or copied, by root into root's own folder, so no program of the user's can swap the
# result before it is installed.
build=$(mktemp -d)
trap 'rm -rf $build' EXIT
if [[ -n $prebuilt ]]; then
  cp $prebuilt $build/pam_wiredpad.so
else
  xcrun clang -O2 -bundle -arch arm64e -arch x86_64 -framework Security -framework CoreFoundation \
    -lpam ${0:A:h}/pam_wiredpad.c -o $build/pam_wiredpad.so
  codesign --force --sign - $build/pam_wiredpad.so
fi

install -d -o root -g wheel -m 755 $base $keys
install -o root -g wheel -m 444 $build/pam_wiredpad.so $module
install -o root -g wheel -m 444 $source_key $keys/$user.pub

# The line goes first, so a missing iPad falls through to Touch ID and then the password.
[[ -f $pam ]] || cp /etc/pam.d/sudo_local.template $pam
remove_lines
{ print -r -- "$line"; cat $pam; } > $pam.wiredpad && cat $pam.wiredpad > $pam && rm $pam.wiredpad
remove_old
print "Installed. sudo now asks the iPad first; without it, Touch ID and the password work as before."
