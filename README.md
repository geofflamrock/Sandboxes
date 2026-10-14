# sbx.app

A macOS app for managing [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) with the `sbx` CLI.

- Lists sandboxes and their state, refreshing every few seconds.
- Starts, stops and removes sandboxes, and opens them in Terminal (double-click a sandbox to attach) or Claude Desktop.
- Creates sandboxes from a v3 workload kit (e.g. `docker/sbx-kit-claude`), with extra mixin kits, a workspace folder (optional), Direct or Clone mode and an optional name. The output of `sbx create` streams into the sheet.
- Remembers workload and kit images you've used.

Requires macOS 26 or later and the `sbx` CLI. The app looks for `sbx` on your login shell's `PATH`; you can set its location in **Settings**.

## Commands it runs

| Action | Command |
| --- | --- |
| List | `sbx ls --json` |
| Create | `sbx create [--name NAME] [--clone] [--kit KIT]... WORKLOAD [PATH]` |
| Start | `sbx run --detach --name NAME` |
| Stop | `sbx stop NAME` |
| Remove | `sbx rm --force NAME` (after confirming in the app) |
| Open in Terminal | `sbx run --name NAME` |
| Open in Claude Desktop | `sbx setup ssh` (first time only), then opens `claude://code/new?ssh_host=NAME.sbx&ssh_folder=WORKSPACE` |

Claude Desktop (v2.110.0 or later) asks you to confirm the SSH connection the first time you open a sandbox in it. Use a sandbox created with a Claude workload so it has Anthropic credentials and network access.

## Getting a build

Every push builds the app in GitHub Actions and uploads it as the `sbx-app` artifact.

The build is ad-hoc signed and not notarized. A browser download is quarantined, so macOS blocks it until you allow it in System Settings. Downloading with the GitHub CLI avoids the quarantine flag entirely:

```bash
gh run download --repo geofflamrock/sbx-app --name sbx-app && ditto -x -k sbx.zip . && rm sbx.zip
```

If you downloaded it in a browser, clear the flag instead:

```bash
xattr -dr com.apple.quarantine sbx.app
```

## Building locally

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open sbx.xcodeproj
```
