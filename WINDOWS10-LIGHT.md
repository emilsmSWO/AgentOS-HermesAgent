# Hermes Light on Windows 10

Build a **remote-only desktop client for Windows 10 Pro 22H2 x64 (Intel/AMD)**.
This produces a **folder application, not an installer or MSIX**. You must already
have access to a remote **Hermes API server (`hermes serve`)**, its URL and its
sign-in method. No local Hermes Python backend is installed by this workflow.

The repository owner reported the manual folder-build procedure working on this
Windows version. The automation was checked with PowerShell 7 on Linux, focused
tests (10 passed, one Windows-only test skipped), and the repository's blocking
static checks. **The automated build, Windows PowerShell 5.1 execution, and GUI
connection were not tested on a Windows host by the agent.**

## Prerequisites

- Windows 10 Pro 22H2 x64 and **64-bit Windows PowerShell 5.1** or PowerShell 7.
  Run as your normal user; the script does not require elevation.
- **Git for Windows**, available as `git.exe` on `PATH`.
- **Node.js for Windows x64 with npm**, available as `node.exe` and `npm.cmd`.
  At the default source revision, the repository requires:
  - Node: `^22.22.0 || ^24.11.0 || >=26.0.0`
  - npm: `<11.10.0 || >=11.17.0`
  Node 22.22.0 is within the Node range, but check npm separately.
  Not every newer Node or npm release is compatible. The script reads the root
  and desktop `package.json` engines at the selected revision and validates them
  with npm's bundled semver parser **before `npm ci`**. Use an official Node
  installation with npm if that parser cannot be located.
- Network access to GitHub, npm and the Electron/build-tool download hosts, plus
  enough disk space for the checkout, dependencies, build caches and application.
  Directory packaging still prepares tool inputs: expect SDK/tool downloads.
  “Light” means remote-only, not a promise of a tiny Electron application.
- **If native dependencies need compilation:** a supported build-time Python and
  Visual Studio Build Tools with the C++ workload / required Windows SDK.
  `node-pty` can fall back to `electron-rebuild` / `node-gyp`. Python used for
  compilation is **not** installation or execution of the Hermes Python backend.
- The Windows HUD helper uses the in-box **.NET Framework C# compiler**
  (`csc.exe`); the script does not install system components for you.

After installing prerequisites, reopen PowerShell and check:

```powershell
git.exe --version
node.exe --version
npm.cmd --version
node.exe -p "process.platform + '-' + process.arch"
```

The last command must print `win32-x64`.

## Run from the repository root

Obtain a repository revision containing this script (the PR branch before merge,
or a revision containing the merged PR). From its root, run:

```powershell
powershell.exe -NoProfile -File .\scripts\install-hermes-light.ps1 -Destination C:\src\hermes-light -Launch
```

This keeps your instruction/script checkout separate from the build checkout at
`C:\src\hermes-light`. That destination must not exist on the first run.
The script obtains sources from
`https://github.com/emilsmSWO/AgentOS-HermesAgent.git`, selects the pinned commit,
sets `HERMES_DESKTOP_VARIANT=light`, then runs, from the build checkout root:

```powershell
npm.cmd ci
npm.cmd run pack --workspace apps/desktop
```

Every native command's exit status is checked. The original working directory
and the two environment variables the script can change are restored, including
after failure. `-Launch` starts the validated application before restoring the
parent environment.

For PowerShell 7, replace `powershell.exe` with `pwsh`.
If execution policy blocks a **reviewed, trusted** downloaded script, use the
process-only invocation below, subject to your organization's policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-hermes-light.ps1 -Destination C:\src\hermes-light -Launch
```

This does not change machine/user execution policy. Do not disable security
software, TLS verification, or change machine-wide execution policy.

### Standalone downloaded script

You do not need a separate full checkout to obtain the orchestrator. Download
`scripts/install-hermes-light.ps1` from this PR/new revision, save it **outside**
the build destination, and review it before running. For example, this URL pins
the script's implementation commit, separately from the sources it builds:

```powershell
New-Item -ItemType Directory -Force C:\src | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/emilsmSWO/AgentOS-HermesAgent/2487be06202b490bfb8afd08998ce1b87d5e5d44/scripts/install-hermes-light.ps1' -OutFile C:\src\install-hermes-light.ps1
# Review C:\src\install-hermes-light.ps1 before executing it.
powershell.exe -NoProfile -File C:\src\install-hermes-light.ps1 -Destination C:\src\hermes-light -Launch
```

The default build pin **predates the new script and this document**. The script
continues executing as an external orchestrator; it does not need its own copy
or any newly added helper files in the pinned checkout.

## Options and repeat runs

| Option | Meaning |
| --- | --- |
| `-Destination <path>` | Absolute local drive path; default `C:\src\hermes-light`. Prefer a short path. Roots, UNC/device paths, nested checkouts and reparse-point ancestors are rejected. |
| `-SourceRef <ref>` | Remote commit SHA, branch or tag; default `7cc3fb8cb55898747dd1dfa56fda3e16ebba028e`. Resolved commit is printed. |
| `-ChangeRef` | Explicitly permit switching a clean existing checkout to the requested commit with detached HEAD. |
| `-Launch` | Start the verified main application EXE after building. Otherwise only print its folder and launch command. |
| `-RemoteUrl <url>` | Optional HTTP(S) server URL inherited by the `-Launch` child via `HERMES_DESKTOP_REMOTE_URL`. No credentials, query or fragment; sign in in the GUI. Without `-Launch`, configure the URL in Settings instead. |

The default SHA is a **reproducibility pin, not the latest release**. Building a
newer ref is not guaranteed equivalent to the owner's validated procedure.
Build only trusted refs: npm lifecycle hooks and the repository's build scripts
execute code.

To use an existing checkout, point `-Destination` at its root. Its `origin` must
be this repository (HTTPS or GitHub SSH), and it must have no tracked edits or
untracked files. If HEAD differs from the resolved source commit, the script
stops unless you supply `-ChangeRef`. For example:

```powershell
powershell.exe -NoProfile -File C:\src\install-hermes-light.ps1 -Destination C:\src\hermes-light -SourceRef main -ChangeRef
```

Repeat runs at the same commit reinstall locked npm dependencies and rebuild.
Ignored build outputs/caches may be replaced; close the running application first.
The script never runs destructive Git reset/clean or discards edits. If the
checkout is dirty, commit/stash your changes yourself or use a fresh destination.
A failed clone/build can leave a partial destination; inspect it yourself rather
than expecting automatic deletion or repair. Refusal to switch an existing
checkout can still leave fetched Git objects, but does not change HEAD or files.

## Output and remote connection

The output is `<Destination>\apps\desktop\release\win-unpacked`, normally:

```powershell
Start-Process -FilePath 'C:\src\hermes-light\apps\desktop\release\win-unpacked\Hermes Light.exe'
```

The script derives the exact main EXE name from the selected product identity
(branding can change the name); use the launch command it prints. It validates
both `build\install-stamp.json` and the packaged `resources\install-stamp.json`
as `payload: light` with `updateMechanism: external`, rejects any packaged
`agent-payload`, and requires the actual main EXE, not a helper executable.
**Keep/copy the entire `win-unpacked` folder**, including DLLs and resources.
Cloned backend source files are not an installed backend and are not the
packaged agent runtime.

In the application:

1. Open **Settings → Gateways → Remote gateway**.
2. Enter the URL of the remote **`hermes serve`** instance (a reverse-proxy path
   prefix is supported).
3. **Sign in** using the method configured by that server.
4. Choose **Save and reconnect**.

The desktop supports multiple registered gateways. This is the Hermes desktop
API server, **not** the Telegram/Discord messaging gateway and **not** a generic
OpenAI-compatible endpoint. See the [desktop guide](website/docs/user-guide/desktop.md)
for server-side setup and authentication.

Use **HTTPS or a trusted VPN** for remote access; never bypass certificate
validation. Do not put passwords/tokens in URLs or script arguments. Optional
`-RemoteUrl 'https://hermes.example.com' -Launch` supplies the URL for that launch
and overrides the saved URL; it does not authenticate you or persist credentials.
For future launches, configure/save the URL through the GUI.

## Troubleshooting and limitations

- **Node/npm engine errors:** check both versions against the selected checkout.
  Install compatible versions, reopen PowerShell, and retry. Do not use force
  flags to bypass engine checks.
- **`node-gyp`, `node-pty`, Python or Visual Studio errors:** install/configure the
  native-build tools listed above if compilation is required. This is not a
  reason to install the Hermes backend or run pip/setup scripts.
- **Blocked `npm.ps1`:** the script deliberately calls `npm.cmd`. Use that form
  for manual npm commands too; no policy change is necessary for npm.
- **Missing .NET Framework helper compiler:** check the error for the expected
  Framework `csc.exe` path and repair/enable the Windows .NET Framework component
  through approved Windows tooling. Node/npm alone cannot provide this compiler.
- **Network/download failures:** inspect the failing native command's output,
  proxy/firewall settings and available disk space. Retry after correcting the
  cause; do not disable TLS checks. No automatic system-package installation occurs.
- **Client offers local-agent installation:** do not accept it. Verify that you
  launched the printed Light EXE and that both artifact stamps say
  `"payload": "light"`, with no packaged `agent-payload`. Rebuild from clean,
  trusted sources if validation fails.
- **Build folder differs on a newer ref:** the script fails if the expected
  `release\win-unpacked` layout/main EXE is absent. Inspect packaging changes;
  do not launch an arbitrary recursively discovered EXE.

Do **not** substitute `npm run dev` (no baked packaged Light stamp), `payload`,
`dist:bundled`, `dist:win`, `setup-hermes` or a Python-backend installer.
The existing MSIX target requires Windows 11 22H2 (`10.0.22621.0`); this workflow
does not lower that floor or install MSIX on Windows 10.
Windows Light folder builds use **external/manual updates**: rebuild a trusted
ref and replace the complete application folder while it is closed. There is no
automatic MSIX updater installation, release publication or update service here.
