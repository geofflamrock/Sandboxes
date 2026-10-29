# Sandboxes

A macOS app for managing [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/).

### Features 

- See the details of your sandboxes, including resource usage, network traffic, and the network and file system rules that apply to them.
- Create new sandboxes quickly and easily.
- Create and manage sandbox [environment files](https://docs.docker.com/ai/sandboxes/configuration/environment-files/) and use them to create sandboxes.
- Start, stop and remove sandboxes.
- Publish a sandbox's ports on your Mac when creating it or later, open them in your browser, and unpublish them.
- Open an interactive shell inside a sandbox in your terminal.
- Run a sandbox's agent in your terminal, or open any sandbox in [Claude Desktop](https://claude.ai/download).
- Get notified when an agent makes a network request that needs approval, and approve or deny across the current or all sandboxes.
- Manage global and sandbox specific secrets.
- Manage global and sandbox specific network rules.
- Manage MCP servers and configure sandboxes to use them.
- Manage agent skills and choose how sandboxes share them.
- View and change `sbx` settings, such as proxies and kit policy, and restart the daemon when a change needs it.
- Install, upgrade and sign in to `sbx` from the app, and run diagnostics to find problems with your setup.

## Getting started

### Requirements

- macOS 26 or later
- The [`sbx` CLI](https://docs.docker.com/ai/sandboxes/). Install it with Homebrew: `brew install docker/tap/sbx`
- `sbx` v0.48.0 or later to unload MCP servers from a sandbox.
- An `sbx` with the experimental `sbx skills` commands (checked against v0.49.1) to manage skills.
- [Claude Desktop](https://claude.ai/download) v2.110.0 or later, to open sandboxes in Claude Desktop. Create the sandbox with the Claude Code agent so it has Anthropic credentials and network access.

### Install

Run this in Terminal to install the latest release into Applications, or to update an existing install:

```bash
curl -fsSL https://geofflamrock.github.io/Sandboxes/install.sh | bash
```

The script is [`site/install.sh`](site/install.sh). It downloads the latest release's DMG, quits Sandboxes if it's running and copies the app into `/Applications`, asking for your password only if you can't write there. A download made with `curl` doesn't have the quarantine flag, so you can skip [Allow the app to run](#allow-the-app-to-run).

Or install it by hand:

1. Download the latest `Sandboxes-<version>.dmg` from [GitHub releases](https://github.com/geofflamrock/Sandboxes/releases/latest).
2. Open the DMG and drag **Sandboxes** onto **Applications**.

### Allow the app to run

If you installed the app by hand: Sandboxes isn't notarized by Apple yet, so the first time you open it macOS blocks it with a message that it can't check the app for malicious software. To allow it:

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

The app looks for `sbx` on your login shell's `PATH`. If it can't find it, set its location in **Settings › sbx**.

## Contributing

### Building locally

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Sandboxes.xcodeproj
```

Local builds show a "Local" badge at the bottom of the sidebar and have version 0.0.0, a placeholder in `project.yml` (`MARKETING_VERSION`). CI sets the real version (see [Test builds](#test-builds) and [Releases](#releases)).

### Update checks

Release builds check the [latest GitHub release](https://github.com/geofflamrock/Sandboxes/releases/latest) at launch and every 6 hours. When it's newer, the sidebar and the menu bar menu link to it. Drafts and pre-releases are ignored.

Other builds don't check. To try it out in one, open **Settings › Development**, turn on **Check for updates in this build** and enter an older version to pretend to be, such as `0.0.1`. You can also check another repository's releases there.

These settings are stored as the `UpdateCheckForceEnabled`, `UpdateCheckCurrentVersion` and `UpdateCheckRepository` defaults, so they also work as launch arguments:

```bash
open Sandboxes.app --args -UpdateCheckForceEnabled YES -UpdateCheckCurrentVersion 0.0.1
```

Release builds ignore them, so values left over from testing a build don't affect a release.

### App icon

The app icon is `Design/AppIcon.icon`, an [Icon Composer](https://developer.apple.com/icon-composer/) file. Its layers are generated by `scripts/generate-app-icon.py`, which also writes a flattened preview to `Design/AppIcon.svg` and the artwork without its background, for the website, to `Design/AppIconArtwork.svg`. In the website's copy, the robot peeks out of the sand when the page loads, unless Reduce Motion is on. To change the artwork, edit the script, then run it from the repository root:

```bash
python3 scripts/generate-app-icon.py
```

To change the background fill, or how the layers are grouped, scaled or lit, open `Design/AppIcon.icon` in Icon Composer.

### Website

The website at [geofflamrock.github.io/Sandboxes](https://geofflamrock.github.io/Sandboxes/) is the static page in `site/`, along with the install script. The `Website` workflow (`.github/workflows/pages.yml`) publishes it to GitHub Pages when `site/` or the icon SVGs in `Design/` change on `main`, copying in `Design/AppIcon.svg` (the favicon) and `Design/AppIconArtwork.svg` (the header's artwork). When it deploys, it fills in the release button with the latest release's version and page, such as "Latest release: v0.6.1", so the button doesn't change after the page loads. Publishing a release redeploys the site once the DMG is attached. Before the first release, and in a local preview, the button says "Latest release" and links to the latest release page.

To preview the site locally at http://localhost:8000:

```bash
scripts/preview-site.sh
```

It assembles `_site/` from symlinks to `site/` and the icon SVGs, so edits show up without running it again. With Node installed, it serves the site with [Browsersync](https://browsersync.io), which reloads the page when a file changes. Otherwise it uses Python's web server, and you reload yourself. Pass a port to use another one, such as `scripts/preview-site.sh 8080`.

### Test builds

Every pull request and every push to `main` uploads a DMG as the `Sandboxes` artifact on the workflow run. Test builds are ahead of the latest release, so their version is the next minor version after it: when the latest release is v0.4.0, they're 0.5.0. Pull request builds are named `Sandboxes-<version>-pr<number>-<commit>.dmg` and `main` builds `Sandboxes-<version>-build<run number>-<commit>.dmg`, where `<commit>` is the short commit SHA. The app shows a badge such as "PR #12 · abc1234" or "main · abc1234" at the bottom of the sidebar so you can tell you're not on a release. **Sandboxes › About Sandboxes** shows the version, build number and, for test builds, the PR or branch and the commit.

To download the latest test build with the GitHub CLI:

```bash
gh run download --repo geofflamrock/Sandboxes --name Sandboxes "$(gh run list --repo geofflamrock/Sandboxes --workflow Build --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
```

### Releases

Publishing a GitHub release builds the app with the release's version and attaches `Sandboxes-<version>.dmg` to it, then redeploys the [website](#website) so its release button shows the new version. Tag releases `v1.2.3` (or `1.2.3`). Release builds show their version, such as "v1.2.3", at the bottom of the sidebar. Builds are ad-hoc signed and not notarized.

### Commands the app runs

| Action | Command |
| --- | --- |
| List | `sbx ls --json` |
| Installed version (home page and Settings › sbx) | `sbx version`, compared with the latest release from the GitHub API for `docker/sbx-releases` |
| Install sbx (home page) | `brew install docker/tap/sbx`, when you click **Install sbx** |
| Upgrade sbx (home page and Settings › sbx) | `brew upgrade docker/tap/sbx` (or the cask it was installed from, such as `sbx@rc`), when you click **Upgrade sbx** |
| Diagnostics (home page and Settings › sbx) | `sbx diagnose --json`, at most every 5 minutes, straight away when `sbx ls` starts failing, or when you click **Run Again** in Settings › sbx or choose **Help › Run sbx Diagnostics…** |
| Start the daemon (home page) | `sbx daemon start --detach`, when the Daemon check fails and you click **Start Daemon** |
| Sign in to Docker (home page) | `sbx login`, when the Authentication check fails and you click **Sign In**. The app shows the one-time code and opens the sign-in page |
| Create | `[DOCKER_SANDBOXES_ROOT_SIZE=SIZE] [DOCKER_SANDBOXES_DOCKER_SIZE=SIZE] [DOCKER_SANDBOXES_CLONED_WORKSPACE_SIZE=SIZE] sbx create [--name NAME] [--clone] [--cpus N] [--memory SIZE] [--env KEY=VALUE]... [--env-file FILE]... [--kit KIT]... [--kit-arg [HANDLE.]NAME=VALUE]... [--static-mcp SERVER]... [--publish [HOST_PORT:]SANDBOX_PORT]... [--deny-network HOST]... [--skills off\|readonly\|readwrite] WORKLOAD [PATH [PATH[:ro]]...]`. An argument is aimed at its kit with the kit's handle only when another picked kit declares the same name. The disk sizes from **Runtime › Disks** and **Workspace › Clone Size** (Clone mode only) are set as `SIZEg`, or as typed for **Custom**, in that `sbx create` process's environment, not your shell's or the sandbox's, since `sbx create` has no flags for them |
| Review an environment file's plan | `sbx env plan [--name NAME] [--clone] [--env-arg NAME=VALUE]... [FILE]`, with the name entered (the file's `name:` to start with), and `--clone` when you choose Clone for a workspace that doesn't set `workspace.clone`. With **Include My Defaults**, it runs in the file's folder without FILE, so sbx adds `~/.sbxenv.yaml`. That's offered when the defaults file exists and the file is called `sbxenv.yaml`, and not for a file in the environment files folder whose defaults would mount the project directory, which would be the file's own folder |
| Create from an environment file | `sbx env create [--name NAME] [--clone] [--env-arg NAME=VALUE]... [FILE] --force`, the same way, after you approve the plan in the app. Ports entered in the New Sandbox window are saved in the file's `ports`, so sbx publishes them from there |
| Read a kit's arguments (New Sandbox window) | `sbx kit inspect KIT --json`, for the workload when it's a kit rather than a built-in agent, and for each mixin kit. sbx refuses to inspect a kit with a required argument that has no value, so the app runs it again with `--kit-arg NAME=VALUE` stand-ins for each argument sbx complains about until it succeeds |
| Start | `sbx run --detach --name NAME` |
| Stop | `sbx stop NAME` |
| Remove | `sbx rm --force NAME` (after confirming in the app) |
| Resource usage (selected running sandbox) | `sbx exec NAME sh -c …` reading `/proc/stat`, `/proc/meminfo`, `/proc/uptime` and `df` |
| Network policy and rules (selected sandbox) | `sbx policy ls NAME --type network --json` |
| File system rules (selected sandbox) | `sbx policy ls NAME --type filesystem --json` |
| Network traffic (selected sandbox) | `sbx policy log NAME --type network --json` |
| Published ports (selected sandbox's Overview) | `sbx ports NAME --json`, every 5 seconds while the sandbox is running and Overview is shown |
| Publish a port | `sbx ports NAME --publish [HOST_PORT:]SANDBOX_PORT`, which starts the sandbox if it's stopped |
| Unpublish a port | `sbx ports NAME --unpublish [HOST_IP:]HOST_PORT:SANDBOX_PORT/PROTOCOL`, as sbx reported the port (after confirming in the app) |
| List network rules (sidebar and Management › Policies) | `sbx policy ls --type network --json` |
| List file system rules (sidebar and Management › Policies) | `sbx policy ls --type filesystem --json` |
| Add a network rule | `sbx policy allow network [--sandbox NAME] [--protocol tcp\|udp\|tcp,udp] HOSTS` or `sbx policy deny network …` with the same arguments |
| Edit a network rule | Removes the rule, then adds it again as above. If adding fails, the old rule is added back |
| Remove a network rule | `sbx policy rm network [--sandbox NAME] --id RULE_ID --force`, or `--resource HOSTS` when sbx doesn't report the rule's ID (after confirming in the app). Rules sbx doesn't mark as editable, such as an organization's or a kit's, can't be changed |
| Check a host (Management › Policies and a sandbox's Policies tab) | `sbx policy check network [--sandbox NAME] [--protocol tcp\|udp] --json TARGET`, without `--sandbox` to check the global policy for all sandboxes |
| Pending approvals | `sbx policy approval ls --json` (or the table output if `--json` isn't supported) |
| Approve a request | `sbx policy approval respond ID --option allow` for this sandbox, or `sbx policy allow network HOST` (with `--method` and `--path` for an HTTP request) followed by `sbx policy approval respond ID --option dismiss` for the request and other sandboxes' requests to the same host when approving for all sandboxes (after confirming in the app) |
| Deny a request | `sbx policy deny network [--sandbox NAME] HOST` (with `--method` and `--path` for an HTTP request), then `sbx policy approval respond ID --option dismiss` for the request, and for other sandboxes' requests to the same host when denying for all sandboxes (after confirming in the app) |
| Dismiss a request | `sbx policy approval respond ID --option dismiss` |
| List secrets (sidebar and Management › Secrets) | `sbx secret ls --json` |
| Add or edit a service secret | `sbx secret set SERVICE --force [--sandbox NAME]`, with the value on standard input, or with `--ref REF` or `--command COMMAND` (and `--refresh POLICY`) |
| Add or edit a custom secret | `sbx secret set-custom --host HOST... [--env NAME] [--placeholder VALUE] [--sandbox NAME]` with `--value VALUE`, `--ref REF` or `--command COMMAND` |
| Add or edit registry credentials | `sbx secret set --registry HOST [--username USER] [--registry-auth-endpoint URL] [--all-sandboxes \| --sandbox NAME] --password-stdin` |
| Remove a secret | `sbx secret rm SERVICE --force [--sandbox NAME]`, `sbx secret rm --placeholder VALUE --force [--sandbox NAME]` for a custom secret, or `sbx secret rm --registry HOST --force [--all-sandboxes \| --sandbox NAME]` for registry credentials (after confirming in the app) |
| List MCP servers (sidebar, Management › MCP Servers, New Sandbox window) | `sbx mcp ls --json` |
| Inspect an MCP server, and its header secrets | `sbx mcp inspect NAME --json` |
| Add an MCP server | For each `${PLACEHOLDER}` in its headers, `sbx secret set mcp:NAME:PLACEHOLDER --force` with the value on standard input, which sbx needs first (removed again if adding fails). Then `sbx mcp add NAME --url URL [--local] [--header 'Name: value']... [--client-id ID] [--scope SCOPE]... [--skip-ssrf-check] --skip-auth`, or `sbx mcp add NAME --command COMMAND [--args ARG]... [--dir DIR]` (after confirming in the app), then authorises it if it needs OAuth |
| Authorise an MCP server | `sbx mcp auth NAME`, with its output shown in the app while sbx waits for you to approve access in the browser |
| Set an MCP header secret | `sbx secret set mcp:NAME:PLACEHOLDER --force`, with the value on standard input |
| Remove an MCP header secret | `sbx secret rm mcp:NAME:PLACEHOLDER --force`, then `sbx secret rm mcp:NAME:PLACEHOLDER:endpoint --force`, which sbx leaves behind (after confirming in the app) |
| Remove an MCP server's credentials | `sbx mcp auth rm NAME --force` (after confirming in the app) |
| Remove an MCP server | `sbx mcp rm NAME --force`, and when you choose **Remove Server and Secrets**, `sbx secret rm mcp:NAME:… --force` for each of its secrets and the records sbx keeps with them (after confirming in the app) |
| Load an MCP server into a running sandbox | `sbx mcp load NAME --sandbox SANDBOX` |
| Unload an MCP server from a running sandbox | `sbx mcp unload NAME --sandbox SANDBOX` (after confirming in the app) |
| List skills (sidebar and Management › Skills) | `sbx skills ls --json`. Each skill's description comes from the `SKILL.md` in the store folder sbx reports, and whether it was added from a repository, and from which commit, from the `sources.json` sbx keeps beside the store. **Inspect…** shows its `SKILL.md`, and **Open in Finder** opens its folder, without running sbx |
| Add skills from a repository | `sbx skills add REPOSITORY [--skill NAME]...`, then with `--force` if sbx says a skill is already installed and you choose to replace it |
| Import skills from your agents on this Mac | `sbx skills import --dry-run` to show what would be imported or replaced, then `sbx skills import --force` when you click **Import** |
| Update a skill added from a repository | `sbx skills update NAME`, or `sbx skills update` for **Update All** |
| Remove a skill | `sbx skills rm NAME --force` (after confirming in the app) |
| List settings (Management › Settings) | `sbx settings ls --json` |
| Read a setting in full (when you edit one, and after changing it) | `sbx settings get KEY --json` |
| Change a setting | `sbx settings set KEY -- VALUE`, from its switch for a boolean or from **Edit…** |
| Reset a setting to its default | `sbx settings unset KEY` |
| Restart the daemon (Management › Settings) | `sbx daemon restart`, after confirming in the app, when you change a setting that needs it or click **Restart Daemon** |
| Open Shell | `sbx exec -it NAME bash`, in Terminal |
| Run the agent (in Terminal) | `sbx run --name NAME` |
| Open in Claude Desktop | `sbx setup ssh` (first time only), then opens `claude://code/new?ssh_host=NAME.sbx&ssh_folder=WORKSPACE` |

Agent and service logos are from [Simple Icons](https://simpleicons.org) (CC0).
