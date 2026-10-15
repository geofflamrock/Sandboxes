# Sandboxes

A macOS app for managing [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/). See all your sandboxes at a glance, create new ones for your favourite coding agent, and keep an eye on what they're doing on the network, without having to remember `sbx` commands.

## Features

### See everything at a glance

- The home page shows how many sandboxes are running or stopped, and any network requests waiting for your approval across all of them.
- The sidebar lists every sandbox with its state and its agent's logo (Claude Code, Codex, Copilot, Cursor, Docker Agent, Gemini, OpenCode, Devin, Droid, Kiro or Shell). It refreshes every few seconds.
- Search the sidebar to filter sandboxes by name.
- Press **⌘[** or the back button to return to the home page from a sandbox.

### Create sandboxes in a few clicks

- Start from a card on the home page for an agent you've used recently, or create one from scratch.
- Pick an agent from a list, or use any v3 workload kit image.
- Add extra mixin kits, choose a workspace folder (optional), pick Direct or Clone mode and give it a name if you like.
- Watch the output as the sandbox is created.
- The app remembers the agents and kits you've used, so they're quick to pick next time.

### Work with your sandboxes

- Start, stop and remove sandboxes. You're asked to confirm before anything is removed.
- Double-click a sandbox to open it in Terminal.
- Open a sandbox in [Claude Desktop](https://claude.ai/download) to work with it in Claude Code. You need Claude Desktop v2.110.0 or later, and it asks you to confirm the SSH connection the first time. Use a sandbox created with the Claude Code agent so it has Anthropic credentials and network access.
- See each sandbox's details, including when it was created, its ports, and CPU, memory and disk usage while it's running.

### Stay in control of network access

- See each sandbox's network policy (allow or deny by default) and the rules that apply to it.
- See which hosts a sandbox has contacted, how many requests it made and whether they were allowed or denied.
- Approve, deny or dismiss network requests that are waiting for approval. Sandboxes with pending requests are marked in the sidebar.

## Getting started

### Requirements

- macOS 26 or later
- The [`sbx` CLI](https://docs.docker.com/ai/sandboxes/)

### Install

1. Download the latest `Sandboxes-<version>.dmg` from [GitHub releases](https://github.com/geofflamrock/Sandboxes/releases/latest).
2. Open the DMG and drag **Sandboxes** onto **Applications**.

### Allow the app to run

Sandboxes isn't notarized by Apple yet, so the first time you open it macOS blocks it with a message that it can't check the app for malicious software. To allow it:

1. Open **Sandboxes** from **Applications** and click **Done** on the warning.
2. Open **System Settings › Privacy & Security**.
3. Scroll down to the message that Sandboxes was blocked and click **Open Anyway**.
4. Click **Open Anyway** again and enter your password when asked.

You only need to do this once. Alternatively, clear the quarantine flag in Terminal after copying the app to Applications:

```bash
xattr -dr com.apple.quarantine /Applications/Sandboxes.app
```

Or download the release with the [GitHub CLI](https://cli.github.com), which doesn't set the quarantine flag at all:

```bash
gh release download --repo geofflamrock/Sandboxes --pattern '*.dmg'
```

### Find `sbx`

The app looks for `sbx` on your login shell's `PATH`. If it can't find it, set its location in **Sandboxes › Settings**.

## Contributing

### Building locally

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Sandboxes.xcodeproj
```

Local builds show a "Local" badge at the bottom of the sidebar. The version lives in `project.yml` (`MARKETING_VERSION`).

### Test builds

Every pull request and every push to `main` uploads a DMG as the `Sandboxes` artifact on the workflow run. Pull request builds are named `Sandboxes-<version>-pr<number>.dmg`, and the app shows a "PR #<number>" badge at the bottom of the sidebar so you can tell you're not on a release. **Sandboxes › About Sandboxes** shows the version, build number and, for test builds, the PR or branch.

To download the latest test build with the GitHub CLI:

```bash
gh run download --repo geofflamrock/Sandboxes --name Sandboxes "$(gh run list --repo geofflamrock/Sandboxes --workflow Build --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
```

### Releases

Publishing a GitHub release builds the app with the release's version and attaches `Sandboxes-<version>.dmg` to it. Tag releases `v1.2.3` (or `1.2.3`). Release builds show their version, such as "v1.2.3", at the bottom of the sidebar. Builds are ad-hoc signed and not notarized.

### Commands the app runs

| Action | Command |
| --- | --- |
| List | `sbx ls --json` |
| Create | `sbx create [--name NAME] [--clone] [--kit KIT]... WORKLOAD [PATH]` |
| Start | `sbx run --detach --name NAME` |
| Stop | `sbx stop NAME` |
| Remove | `sbx rm --force NAME` (after confirming in the app) |
| Resource usage (selected running sandbox) | `sbx exec NAME sh -c …` reading `/proc/stat`, `/proc/meminfo`, `/proc/uptime` and `df` |
| Network policy and rules (selected sandbox) | `sbx policy ls NAME --type network --json` |
| Network traffic (selected sandbox) | `sbx policy log NAME --type network --json` |
| Pending approvals | `sbx policy approval ls --json` (or the table output if `--json` isn't supported) |
| Approve a request | `sbx policy approval respond ID --option allow` (after confirming in the app) |
| Deny a request | `sbx policy deny network [--sandbox NAME] HOST` (with `--method` and `--path` for an HTTP request), then `sbx policy approval respond ID --option dismiss` for the request, and for other sandboxes' requests to the same host when denying for all sandboxes (after confirming in the app) |
| Dismiss a request | `sbx policy approval respond ID --option dismiss` |
| Open in Terminal | `sbx run --name NAME` |
| Open in Claude Desktop | `sbx setup ssh` (first time only), then opens `claude://code/new?ssh_host=NAME.sbx&ssh_folder=WORKSPACE` |

Agent logos are from [Simple Icons](https://simpleicons.org) (CC0).
