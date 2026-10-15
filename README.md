# Sandboxes

A macOS app for managing [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) with the `sbx` CLI.

- Lists sandboxes and their state, refreshing every few seconds. Each sandbox shows its agent's logo (Claude Code, Codex, Copilot, Cursor, Docker Agent, Gemini, OpenCode), or a symbol for Devin, Droid, Kiro and Shell. Logos are from [Simple Icons](https://simpleicons.org) (CC0).
- Starts, stops and removes sandboxes, and opens them in Terminal (double-click a sandbox to attach) or Claude Desktop.
- Creates sandboxes for an agent picked from a list (Claude Code maps to `docker/sbx-kit-claude`, and so on) or any v3 workload kit image, with extra mixin kits, a workspace folder (optional), Direct or Clone mode and an optional name. The output of `sbx create` streams into the sheet.
- Remembers agent and kit images you've used.
- Shows each sandbox's network policy (allow or deny by default), the network rules that apply to it, and the hosts it has contacted, with request counts and whether they were allowed or denied.
- Lists network requests waiting for approval, with Approve and Deny buttons (confirmed before running), and marks sandboxes with pending approvals in the sidebar.

Requires macOS 26 or later and the `sbx` CLI. The app looks for `sbx` on your login shell's `PATH`; you can set its location in **Settings**.

## Commands it runs

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
| Approve or deny a request | `sbx policy approval respond ID --option OPTION` (after confirming in the app) |
| Open in Terminal | `sbx run --name NAME` |
| Open in Claude Desktop | `sbx setup ssh` (first time only), then opens `claude://code/new?ssh_host=NAME.sbx&ssh_folder=WORKSPACE` |

Claude Desktop (v2.110.0 or later) asks you to confirm the SSH connection the first time you open a sandbox in it. Use a sandbox created with a Claude workload so it has Anthropic credentials and network access.

## Getting a build

**Releases.** Publishing a GitHub release builds the app with the release's version and attaches `Sandboxes-<version>.dmg` to it. Tag releases `v1.2.3` (or `1.2.3`). Release builds show their version, such as "v1.2.3", at the bottom of the sidebar.

**Test builds.** Every pull request and every push to `main` uploads a DMG as the `Sandboxes` artifact on the workflow run. Pull request builds are named `Sandboxes-<version>-pr<number>.dmg`, and the app shows a "PR #<number>" badge at the bottom of the sidebar so you can tell you're not on a release.

Open the DMG and drag **Sandboxes** onto **Applications**. **Sandboxes › About Sandboxes** shows the version, build number and, for test builds, the PR or branch.

The build is ad-hoc signed and not notarized. A browser download is quarantined, so macOS blocks the app until you allow it in System Settings. Downloading with the GitHub CLI avoids the quarantine flag entirely. For the latest release:

```bash
gh release download --repo geofflamrock/sbx-app --pattern '*.dmg'
```

For the latest test build:

```bash
gh run download --repo geofflamrock/sbx-app --name Sandboxes "$(gh run list --repo geofflamrock/sbx-app --workflow Build --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
```

If you downloaded it in a browser, clear the flag after copying the app to Applications:

```bash
xattr -dr com.apple.quarantine /Applications/Sandboxes.app
```

## Building locally

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Sandboxes.xcodeproj
```

Local builds show a "Local" badge. The version lives in `project.yml` (`MARKETING_VERSION`).
