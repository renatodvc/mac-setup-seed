#!/usr/bin/env bash
# bootstrap.sh — stock macOS to a running `apply`, in one command.
#
#   curl -fsSL -o /tmp/mac-bootstrap.sh \
#     https://raw.githubusercontent.com/renatodvc/mac-setup-seed/main/bootstrap.sh \
#     && bash /tmp/mac-bootstrap.sh
#
# It holds no credential, and it knows exactly one thing about the content
# repository: that `./setup apply` at the clone root starts the engine
# ([R-115]). Nothing else about that repository's structure appears here.
#
# Written for the bash a stock macOS carries — 3.2, from 2007. No associative
# arrays, no ${var,,}, nothing from bash 4. The documented command invokes bash
# explicitly, so the shebang and the invocation agree ([D-004]).
set -euo pipefail

# --- constants -------------------------------------------------------------

# The content repository. Public exposure is its name, which [D-028] accepted as
# the minor cost of a public bootstrap. SETUP_REPO overrides it, for a bench run
# against a branch or a fork.
SETUP_REPO=${SETUP_REPO:-renatodvc/mac-setup}

# The repository path is load-bearing: every symlink the engine delivers points
# into it ([R-511], [D-022]).
CLONE_PATH="$HOME/contexts/setup"

# Apple Silicon only, so the prefix is a constant ([D-041]).
BREW_PREFIX=/opt/homebrew

# "Current macOS" is a floor, not an equality ([R-105], [D-041]). A Mac that
# ships newer runs untested and is not blocked; below the baseline this stops.
MACOS_MAJOR_FLOOR=26

# A floor with room for the first converge, not a measurement: Command Line
# Tools is roughly 3 GB and Homebrew with git, gh and ansible roughly 1.5 GB,
# and then the casks arrive. Adjustable once the package lists make the real
# number knowable.
MIN_DISK_GB=20

# The headless Command Line Tools route is not ours and has broken between
# macOS releases before ([L-002]). The GUI fallback covers it.
CLT_SENTINEL=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
CLT_POLL_SECONDS=15
CLT_POLL_TRIES=120

EXIT_OK=0
EXIT_FAILED=1
EXIT_REFUSED=2

NO_APPLY=""
PREFLIGHT_ONLY=""

# --- output ----------------------------------------------------------------

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
skip() { printf '    (already done: %s)\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

fail() {
    warn ""
    warn "Failed: $*"
    warn ""
    exit "$EXIT_FAILED"
}

refuse() {
    warn ""
    warn "Refused: $*"
    warn ""
    exit "$EXIT_REFUSED"
}

usage() {
    cat <<USAGE
Usage: bash bootstrap.sh [options]

Takes a stock Mac to a converged one: Xcode Command Line Tools, Homebrew,
git, gh and Ansible, a GitHub sign-in, a clone of the content repository to
\$HOME/contexts/setup, and then \`./setup apply\`.

Options
  --no-apply        Stop after the clone and print the handover command
  --preflight-only  Run the checks and exit, changing nothing
  --help            This text

Environment
  SETUP_REPO        owner/repo of the content repository
                    (default: $SETUP_REPO)

Exit codes
  0  reached the handover, or the engine returned 0
  3  the engine converged but advises a second run
  1  a step failed; the message names it
  2  refused before doing anything
USAGE
}

# --- arguments -------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
    --no-apply) NO_APPLY=1 ;;
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    -h | --help)
        usage
        exit "$EXIT_OK"
        ;;
    *)
        warn "Unknown argument: $1"
        usage >&2
        exit "$EXIT_REFUSED"
        ;;
    esac
    shift
done

# --- preflight -------------------------------------------------------------

# Read-only, and it refuses before touching anything ([R-105]). Exit 2
# matches the engine's "refused before doing anything", so one convention covers
# both halves of a first run.
preflight() {
    local version major probe available

    step "Preflight"

    [ "$(id -u)" != "0" ] ||
        refuse "do not run this as root. A root-owned Homebrew prefix is a repair job, not a setup."

    [ "$(uname -s)" = "Darwin" ] ||
        refuse "this is macOS only ([D-041]). Found $(uname -s)."

    [ "$(uname -m)" = "arm64" ] ||
        refuse "this supports Apple Silicon only ([D-041]). Found $(uname -m)."

    version=$(sw_vers -productVersion)
    major=${version%%.*}
    [ "$major" -ge "$MACOS_MAJOR_FLOOR" ] ||
        refuse "this needs macOS $MACOS_MAJOR_FLOOR or newer ([R-105], [D-041]). Found $version."

    probe="$HOME/.mac-setup-bootstrap-probe.$$"
    if ! (: >"$probe") 2>/dev/null; then
        refuse "\$HOME is not writable: $HOME. Everything after this writes there."
    fi
    rm -f "$probe"

    curl -fsI --max-time 10 https://github.com >/dev/null 2>&1 ||
        refuse "github.com is not reachable. Both remaining downloads and the clone are GitHub."

    available=$(df -g /System/Volumes/Data | awk 'NR == 2 { print $4 }')
    case "$available" in
    '' | *[!0-9]*) refuse "could not read the free space on /System/Volumes/Data." ;;
    esac
    [ "$available" -ge "$MIN_DISK_GB" ] ||
        refuse "this needs about ${MIN_DISK_GB} GB free and finds ${available} GB."

    say "    macOS $version on $(uname -m), ${available} GB free, github.com reachable."
}

# --- the interaction summary ----------------------------------------------

# Printed before anything happens, so the operator knows what is coming and can
# stay at the machine for the right minutes. Everything here belongs to the
# bootstrap's own block, which is not one of the engine's three windows: it runs
# before Ansible exists ([D-012], [D-028]).
announce() {
    cat <<ANNOUNCE

This will ask you for three things, and nothing else:

  1. Command Line Tools    only if the headless install does not work — then
                           macOS opens a dialog and you click Install
  2. your Mac password     Homebrew's installer needs sudo
  3. a GitHub sign-in      gh opens a browser; sign in as the account that can
                           read $SETUP_REPO

After that it runs unattended until the engine takes over, and the engine has
its own interaction windows.

ANNOUNCE
}

# --- step 1: Xcode Command Line Tools -------------------------------------

clt_present() {
    xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1
}

# The label changes with every macOS release, so it is read rather than
# hard-coded. `softwareupdate -l` only lists Command Line Tools while the
# sentinel exists, which is the whole trick ([L-002]).
clt_label() {
    softwareupdate -l 2>/dev/null |
        grep -E 'Label: Command Line Tools' |
        tail -1 |
        sed -e 's/^ *\* *Label: *//' -e 's/ *$//'
}

clt_install_headless() {
    local label

    : >"$CLT_SENTINEL"
    label=$(clt_label || true)
    if [ -z "$label" ]; then
        rm -f "$CLT_SENTINEL"
        return 1
    fi

    say "    installing \"$label\" without a dialog"
    if softwareupdate -i "$label" --verbose; then
        rm -f "$CLT_SENTINEL"
        # Tested, not assumed: `softwareupdate` has been known to report success
        # for a Command Line Tools install that did not produce a usable git.
        # And it is tested inside an `if`, because a bare call under `set -e`
        # would exit the whole script instead of falling through to the dialog.
        if clt_present; then return 0; fi
        return 1
    fi
    rm -f "$CLT_SENTINEL"
    return 1
}

clt_install_gui() {
    local tries=0

    say "    falling back to the dialog: click Install in the window macOS opens"
    xcode-select --install >/dev/null 2>&1 || true

    while [ "$tries" -lt "$CLT_POLL_TRIES" ]; do
        if clt_present; then return 0; fi
        sleep "$CLT_POLL_SECONDS"
        tries=$((tries + 1))
    done
    return 1
}

install_command_line_tools() {
    step "Xcode Command Line Tools"

    if clt_present; then
        skip "$(xcode-select -p)"
        return 0
    fi

    if clt_install_headless; then
        say "    installed without a dialog"
        return 0
    fi

    if clt_install_gui; then
        say "    installed through the dialog"
        return 0
    fi

    fail "Command Line Tools did not install. Run \`xcode-select --install\` by hand,
       or install Xcode from the App Store, then run this script again.
       This is the most fragile step here, and it is not ours ([L-002])."
}

# --- step 2: Homebrew ------------------------------------------------------

install_homebrew() {
    step "Homebrew"

    if [ -x "$BREW_PREFIX/bin/brew" ]; then
        skip "$("$BREW_PREFIX/bin/brew" --version | head -1)"
        PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"
        export PATH
        return 0
    fi

    # Asked for at one named moment, rather than letting the installer surprise
    # the operator mid-download ([D-012]'s principle, inside this block).
    say "    Homebrew's installer needs sudo. Your Mac password, once:"
    sudo -v || fail "sudo was refused, and Homebrew's installer needs it."

    # A piped remote script, which is exactly what the entry command above
    # rejects for itself. It stays because it is Homebrew's only supported
    # install path, and maintaining a fork of somebody else's installer inside
    # the least-tested part of the system would be worse. Deliberate, and
    # recorded here so it does not read as an oversight.
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ||
        fail "Homebrew's installer did not finish."

    [ -x "$BREW_PREFIX/bin/brew" ] ||
        fail "Homebrew reported success and $BREW_PREFIX/bin/brew is not there."

    PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"
    export PATH
}

# --- step 3: git, gh, ansible ---------------------------------------------

# Two environment variables, and neither is optional ([L-071]). They cover the
# path nobody tests: a person in Terminal.
#
# NONINTERACTIVE=1 — Homebrew 6.0.18 asks "Do you want to proceed with the
# installation? [y/n]" when stdin is a TERMINAL. Without it a human running this
# script is asked three times, for `git`, `gh` and `ansible`, while the announce
# above promises three named questions and then unattended running. Homebrew
# proceeds silently with no terminal, which is why no automated path sees it.
#
# HOMEBREW_NO_AUTO_UPDATE=1 — `brew install` updates Homebrew itself first, by
# default, and that update is unconditional network work ([R-504]).
install_formula() {
    # install_formula <formula> <binary it provides>
    if [ -x "$BREW_PREFIX/bin/$2" ]; then
        skip "$2"
        return 0
    fi
    say "    installing $1"
    NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 brew install "$1" ||
        fail "brew install $1 did not finish."
    [ -x "$BREW_PREFIX/bin/$2" ] ||
        fail "brew installed $1 and $BREW_PREFIX/bin/$2 is not there."
}

install_tools() {
    step "git, gh, and Ansible"
    install_formula git git
    install_formula gh gh
    install_formula ansible ansible-playbook
}

# --- step 4: the GitHub sign-in -------------------------------------------

sign_in_to_github() {
    step "GitHub sign-in"

    if gh auth status >/dev/null 2>&1; then
        skip "gh is already signed in"
        return 0
    fi

    say "    gh will open a browser. Sign in as the account that can read $SETUP_REPO."
    gh auth login --hostname github.com --git-protocol https --web ||
        fail "the GitHub sign-in did not complete. Run \`gh auth login\` by hand, then run this again."
}

# --- step 5: the clone ----------------------------------------------------

# True when the work tree at $1 has a remote naming $SETUP_REPO, in either URL
# form. This is the only check of the clone's remote: nothing after the
# bootstrap re-checks it, so a repository swapped or repointed by hand at
# $HOME/contexts/setup is converged from without complaint. A known gap.
is_our_work_tree() {
    local url
    url=$(git -C "$1" remote get-url origin 2>/dev/null || true)
    case "$url" in
    *"$SETUP_REPO" | *"$SETUP_REPO".git) return 0 ;;
    *) return 1 ;;
    esac
}

clone_content_repository() {
    step "The content repository"

    if [ -e "$CLONE_PATH" ] || [ -L "$CLONE_PATH" ]; then
        if is_our_work_tree "$CLONE_PATH"; then
            # Never pull. The bootstrap does not update the repository — that is
            # the operator's `git pull`, and seed-only is the discipline
            # everywhere else too ([D-054]).
            skip "$CLONE_PATH is already a clone of $SETUP_REPO"
            return 0
        fi
        refuse "something else is at $CLONE_PATH, and this path is where the repository
          must live ([R-511], [D-022]). Move it aside and run this again.
          [D-035]'s back-up-and-continue rule is about files, not about the one
          directory the whole design is anchored to."
    fi

    mkdir -p "$HOME/contexts"
    say "    cloning $SETUP_REPO into $CLONE_PATH"
    # --recurse-submodules is load-bearing, not tidiness ([D-155]). vendor/ holds
    # a submodule, and declarations inside the content repository name paths
    # inside it. Without recursion the directory is empty, those paths do not
    # exist, and whatever reads them fails — with nothing here reporting it,
    # because the clone succeeded.
    gh repo clone "$SETUP_REPO" "$CLONE_PATH" -- --recurse-submodules ||
        fail "the clone did not finish. Check that this account can read $SETUP_REPO."
}

# --- step 6: the handover -------------------------------------------------

# The one thing this script assumes about the content repository ([R-115]).
hand_over() {
    step "Handover"

    if [ ! -x "$CLONE_PATH/setup" ]; then
        fail "$CLONE_PATH/setup is missing or not executable.
       This script expects an executable \`setup\` at the repository root, taking
       the verb \`apply\`. That contract is the only thing it knows about the
       content repository ([R-115]), so a break here means the repository is not
       what this script was written against."
    fi

    if [ -n "$NO_APPLY" ]; then
        say ""
        say "Stopping before the converge, as asked. Start it with:"
        say ""
        say "    $CLONE_PATH/setup apply"
        say ""
        exit "$EXIT_OK"
    fi

    say "    handing over to the engine; its exit code becomes this script's"
    say ""
    # exec, so the engine's exit code is this script's — including 3, which means
    # converged but a second run is advised ([R-110]).
    exec "$CLONE_PATH/setup" apply
}

# --- main ------------------------------------------------------------------

main() {
    preflight

    if [ -n "$PREFLIGHT_ONLY" ]; then
        say ""
        say "Preflight only, as asked. Nothing was changed."
        exit "$EXIT_OK"
    fi

    announce
    install_command_line_tools
    install_homebrew
    install_tools
    sign_in_to_github
    clone_content_repository
    hand_over
}

main
