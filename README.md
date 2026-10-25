# mac-setup-seed

One command takes a stock Mac to a configured one.

```sh
curl -fsSL -o /tmp/mac-bootstrap.sh \
  https://raw.githubusercontent.com/renatodvc/mac-setup-seed/main/bootstrap.sh \
  && bash /tmp/mac-bootstrap.sh
```

The script is downloaded to disk before it runs, on purpose: a cut connection
cannot half-run it, and it can be re-read or re-run without downloading again.

## What it does

Xcode Command Line Tools → Homebrew → `git`, `gh` and Ansible → a GitHub
sign-in → clone the private content repository to `$HOME/contexts/setup` →
`./setup apply`.

Every step is a presence check followed by an action, so running it again on a
configured machine installs nothing, clones nothing, signs in to nothing, and
still reaches the handover.

**Re-running it never updates the clone, either.** When the content repository
is already at `$HOME/contexts/setup`, the script says so and does not pull. It
only checks out the submodules the clone lacks — after a first clone that
stopped at its submodules, or a submodule added since — at the commit the clone
pins, and it never moves one that is already checked out. Updating the
repository is your own `git pull`.

## The three things it asks you for

It prints these before doing anything, so you know how long to stay at the
machine.

| | What you do | Avoidable? |
| --- | --- | --- |
| **Command Line Tools** | click **Install** and wait | only on the fallback path — the headless attempt avoids it when it works |
| **your Mac password** | type it once | no. Homebrew's installer needs `sudo` |
| **GitHub sign-in** | complete the browser flow `gh` opens | no. This is the one deliberate interactive step |

Nothing else here prompts. After the handover, prompting is the engine's
business and it has its own interaction windows.

## Options

| | |
| --- | --- |
| `--no-apply` | stop after the clone and print the handover command |
| `--preflight-only` | run the checks and exit, changing nothing |
| `--help` | the usage text |
| `SETUP_REPO=owner/repo` | override the content repository, for testing against a branch or a fork |

## Exit codes

| | |
| --- | --- |
| `0` | reached the handover, or the engine returned `0` |
| `3` | the engine converged and advises a second run |
| `1` | a step failed; the message names it and what to do |
| `2` | refused before doing anything — a preflight check, or something unexpected at the clone path |

Resuming is running it again.

## What it refuses

Running as root, anything but Apple Silicon, macOS older than 27, an unwritable
`$HOME`, no network, less than 20 GB free, a terminal without Full Disk Access,
or something that is not the content repository sitting at `$HOME/contexts/setup`.

**Give the terminal Full Disk Access before you run it**: System Settings →
Privacy & Security → Full Disk Access → +, add the terminal, turn it on, then
quit and open the terminal again. The first converge runs in this terminal, and
without the grant macOS hides Chrome's data from it.

## Before pushing a change

```sh
shellcheck bootstrap.sh
```

By hand, every time. It runs before anything is installed, and the only
environment that can test it from stock macOS is a fresh virtual machine.

## What is not here

This repository holds this script and this README, and nothing else. It needs no
credential to read, and it never depends on the private repository's internal
structure — its single assumption is that `$HOME/contexts/setup/setup apply`
starts the engine.
