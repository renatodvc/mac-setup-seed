#!/usr/bin/env bash
#
# mac-setup bootstrap
# -------------------
# The only thing you run by hand on a fresh Mac:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/renatodvc/mac-setup-seed/main/bootstrap.sh)"
#
# (Use that exact form, NOT `curl | bash` — the script has interactive
# prompts and needs the terminal's stdin.)
#
# It installs the bare minimum (Xcode Command Line Tools, Homebrew, ansible,
# gh), authenticates with GitHub in the browser, clones the private mac-setup
# repo and hands off to the Ansible playbook. Everything else lives there.
#
# This file's home is the private repo; it is mirrored to the public seed repo
# with scripts/publish-seed.sh. Edit it in the private repo only.

set -euo pipefail

GITHUB_REPO="renatodvc/mac-setup"        # private repo with the playbook
REPO_DIR="$HOME/code/private/mac-setup"  # where it gets cloned

log()  { printf '\n\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "This script only runs on macOS."
[[ "$(uname -m)" == "arm64" ]]  || fail "This setup targets Apple Silicon only."

# --- 1. Xcode Command Line Tools (git + compilers; needed by Homebrew) -------
if ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools — click 'Install' in the dialog..."
  xcode-select --install >/dev/null 2>&1 || true
  until xcode-select -p >/dev/null 2>&1; do
    sleep 10
  done
fi
log "Command Line Tools present."

# --- 2. Homebrew --------------------------------------------------------------
BREW=/opt/homebrew/bin/brew
if [[ ! -x "$BREW" ]]; then
  log "Installing Homebrew (you may be asked for your macOS password)..."
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$("$BREW" shellenv)"
log "Homebrew ready."

# --- 3. Tools the bootstrap itself needs --------------------------------------
log "Installing ansible and gh..."
brew list --formula ansible >/dev/null 2>&1 || brew install ansible
brew list --formula gh      >/dev/null 2>&1 || brew install gh

# --- 4. GitHub authentication (interactive, once) ------------------------------
if ! gh auth status >/dev/null 2>&1; then
  log "Authenticating with GitHub — follow the browser device flow..."
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git
log "GitHub authenticated as $(gh api user -q .login)."

# --- 5. Clone / update the private repo ----------------------------------------
if [[ -d "$REPO_DIR/.git" ]]; then
  log "Repo already cloned — pulling latest..."
  git -C "$REPO_DIR" pull --ff-only
else
  log "Cloning $GITHUB_REPO into $REPO_DIR..."
  mkdir -p "$(dirname "$REPO_DIR")"
  gh repo clone "$GITHUB_REPO" "$REPO_DIR"
fi

# --- 6. Hand off to Ansible -----------------------------------------------------
cd "$REPO_DIR/ansible"
log "Installing required Ansible collections..."
ansible-galaxy collection install -r requirements.yml

log "Starting the playbook. You'll be asked for two passwords:"
log "  BECOME password = your macOS user password (sudo)"
log "  Vault password  = the ansible-vault password for secrets.yml"
ansible-playbook site.yml --ask-become-pass --ask-vault-pass

log "Unattended phase complete."
log "Next: open $REPO_DIR/MANUAL.md and work through the two interactive batches."
