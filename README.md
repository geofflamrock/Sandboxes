# sbx.app

A macOS app for managing [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) with the `sbx` CLI.

- Lists sandboxes and their state, refreshing every few seconds.
- Starts, stops and removes sandboxes, and opens them in Terminal (double-click a sandbox to attach).
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

## Getting a build

Every push builds the app in GitHub Actions. Download the `sbx-app` artifact from the workflow run and unzip it twice (the artifact is a zip that contains `sbx.zip`).

The build is ad-hoc signed and not notarized, so clear the quarantine flag before opening it:

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
