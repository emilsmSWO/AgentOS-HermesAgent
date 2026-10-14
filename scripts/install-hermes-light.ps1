#requires -Version 5.1
<#
.SYNOPSIS
Build the remote-only Hermes Light folder application on Windows x64.
.DESCRIPTION
Uses npm's locked dependencies and desktop pack target, never a backend installer
or MSIX. The default source commit is a reproducibility pin, not a latest release.
Existing checkouts must be clean; changing their HEAD requires -ChangeRef.
#>
[CmdletBinding()]
param(
    [string]$Destination = 'C:\src\hermes-light',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string]$SourceRef = '7cc3fb8cb55898747dd1dfa56fda3e16ebba028e',
    [switch]$ChangeRef,
    [switch]$Launch,
    [string]$RemoteUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Argument arrays are passed directly, never evaluated as command strings.
function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed (exit $LASTEXITCODE). See the output above."
    }
}

function Assert-LightArtifact {
    param([string]$DesktopRoot, [string]$ExecutableName)
    $folder = Join-Path $DesktopRoot 'release\win-unpacked'
    foreach ($stampPath in @(
        (Join-Path $DesktopRoot 'build\install-stamp.json'),
        (Join-Path $folder 'resources\install-stamp.json')
    )) {
        $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
        if ($stamp.payload -ne 'light' -or $stamp.updateMechanism -ne 'external') {
            throw "Not a Windows Light artifact: $stampPath. Do not launch it."
        }
    }
    # Check the whole packaged folder, not just the expected resources location.
    $payload = @(Get-ChildItem -LiteralPath $folder -Recurse -Force |
        Where-Object { $_.Name -eq 'agent-payload' })
    if ($payload.Count -ne 0) { throw "Packaged agent-payload found in $folder. Do not launch it." }
    if ([IO.Path]::GetFileName($ExecutableName) -ne $ExecutableName -or
        [string]::IsNullOrWhiteSpace($ExecutableName)) {
        throw 'Invalid Windows executable name from product identity.'
    }
    $exe = Join-Path $folder ($ExecutableName + '.exe')
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Main Light executable missing: $exe"
    }
    return $exe
}

$originalLocation = Get-Location
$originalVariant = [Environment]::GetEnvironmentVariable('HERMES_DESKTOP_VARIANT', 'Process')
$originalRemote = [Environment]::GetEnvironmentVariable('HERMES_DESKTOP_REMOTE_URL', 'Process')
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not [Environment]::Is64BitOperatingSystem -or
        $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Use a 64-bit PowerShell on Windows x64 (Intel/AMD), not ARM64 or WSL.'
    }
    if ($RemoteUrl) {
        $uri = $null
        if (-not [Uri]::TryCreate($RemoteUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo -or
            $uri.Query -or $uri.Fragment) {
            throw 'RemoteUrl must be an HTTP(S) server URL without credentials, query or fragment. Sign in in the GUI.'
        }
    }
    # Reject roots, UNC/device paths and redirected paths before obtaining sources.
    if ($Destination -notmatch '^[A-Za-z]:[\\/]') {
        throw 'Destination must be an absolute local drive path, for example C:\src\hermes-light.'
    }
    $Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    if ($Destination -eq [IO.Path]::GetPathRoot($Destination).TrimEnd('\', '/')) {
        throw 'Destination cannot be a drive root.'
    }
    $ancestor = $Destination
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Unsafe destination ancestor (file or reparse point): $ancestor"
            }
        }
        if ($ancestor -ne $Destination -and
            (Test-Path -LiteralPath (Join-Path $ancestor '.git'))) {
            throw 'Do not build in a nested checkout. Choose a separate destination.'
        }
        $ancestor = Split-Path -Path $ancestor -Parent
    }
    $git = (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)
    $node = (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue)
    $npm = (Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue)
    if (-not $git -or -not $node -or -not $npm) {
        throw 'Install Git for Windows and a supported Node.js with npm; reopen PowerShell so git.exe, node.exe and npm.cmd are on PATH.'
    }
    Invoke-Native $git.Source @('--version')
    $nodeHost = Invoke-Native $node.Source @('-p', "process.platform + '-' + process.arch")
    if ($nodeHost -ne 'win32-x64') { throw 'Install the Windows x64 edition of Node.js.' }
    $npmVersion = (Invoke-Native $npm.Source @('--version') | Out-String).Trim()

    $existing = Test-Path -LiteralPath $Destination
    if ($existing) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination '.git'))) {
            throw 'Destination already exists but is not a checkout. Choose a new path; nothing will be overwritten.'
        }
        $top = (Invoke-Native $git.Source @('-C', $Destination, 'rev-parse', '--show-toplevel') | Out-String).Trim()
        if ([IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ne $Destination) {
            throw 'Destination must be the checkout root.'
        }
        $origin = (Invoke-Native $git.Source @('-C', $Destination, 'remote', 'get-url', 'origin') | Out-String).Trim()
        if ($origin -notmatch '^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)emilsmSWO/AgentOS-HermesAgent(?:\.git)?/?$') {
            throw 'Existing checkout origin is not emilsmSWO/AgentOS-HermesAgent.'
        }
        $dirty = @(Invoke-Native $git.Source @('-C', $Destination, 'status', '--porcelain', '--untracked-files=all'))
        if ($dirty.Count) {
            throw 'Checkout has edits or untracked files. Commit/stash them yourself or choose a fresh destination.'
        }
    } else {
        $parent = Split-Path -Path $Destination -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Invoke-Native $git.Source @('clone', '--depth', '1', 'https://github.com/emilsmSWO/AgentOS-HermesAgent.git', $Destination)
    }
    Set-Location -LiteralPath $Destination
    # Always resolve the requested remote ref; never reset/clean user files.
    Invoke-Native $git.Source @('fetch', '--depth', '1', 'origin', $SourceRef)
    $target = Invoke-Native $git.Source @('rev-parse', '--verify', 'FETCH_HEAD^{commit}')
    $head = Invoke-Native $git.Source @('rev-parse', 'HEAD')
    if ($target -ne $head) {
        if ($existing -and -not $ChangeRef) {
            throw "Requested ref resolves to $target; checkout is $head. Use -ChangeRef to explicitly allow a detached checkout, or choose a new destination."
        }
        Invoke-Native $git.Source @('checkout', '--detach', $target)
    }
    Write-Host "Building source commit: $target"

    # npm ships semver. Use that parser before ci (no downloaded helper or npx).
    # Standard Windows Node installs keep npm beside npm.cmd; global installs
    # may instead expose it under npm root -g.
    $globalRoot = (Invoke-Native $npm.Source @('root', '-g') | Out-String).Trim()
    $npmBase = Split-Path -Path $npm.Source -Parent
    $engineCheck = @'
const fs = require('fs');
const path = require('path');
const { createRequire } = require('module');
const [npmBase, globalRoot, npmVersion] = process.argv.slice(1);
let semver;
for (const base of [path.join(npmBase, 'node_modules', 'npm'), path.join(globalRoot, 'npm')]) {
  try { semver = createRequire(path.join(base, 'package.json'))('semver'); break; } catch {}
}
if (!semver) throw new Error('Cannot locate npm bundled semver. Use an official Node.js installation with npm.');
for (const file of ['package.json', 'apps/desktop/package.json']) {
  const engines = JSON.parse(fs.readFileSync(file, 'utf8')).engines || {};
  for (const [tool, version] of [['node', process.versions.node], ['npm', npmVersion]]) {
    if (engines[tool] && !semver.satisfies(version, engines[tool])) {
      throw new Error(`${file} requires ${tool} ${engines[tool]}; installed ${version}. Install a compatible version and retry.`);
    }
  }
}
'@
    Invoke-Native $node.Source @('-e', $engineCheck, $npmBase, $globalRoot, $npmVersion)

    $env:HERMES_DESKTOP_VARIANT = 'light'
    # Native dependency compilation can require Python and VS C++ build tools.
    # These are build tools, not an installation of the Hermes Python backend.
    Invoke-Native $npm.Source @('ci')
    Invoke-Native $npm.Source @('run', 'pack', '--workspace', 'apps/desktop')
    $identityCheck = @'
const identity = require('./apps/desktop/product-identity.cjs');
if (!identity.light) throw new Error('Product identity is not Light');
console.log(identity.windowsExecutableName || identity.displayName);
'@
    $exeName = (Invoke-Native $node.Source @('-e', $identityCheck) | Out-String).Trim()
    $exe = Assert-LightArtifact (Join-Path $Destination 'apps\desktop') $exeName
    $folder = Split-Path -Path $exe -Parent
    Write-Host "Verified Light folder: $folder"
    Write-Host 'Keep/copy the entire folder. Updates are external/manual, not MSIX.'
    Write-Host ("Launch: Start-Process -FilePath '{0}'" -f $exe.Replace("'", "''"))
    if ($RemoteUrl) {
        if (-not $Launch) { Write-Warning 'RemoteUrl only applies to -Launch; otherwise configure the server URL in Settings > Gateways.' }
        $env:HERMES_DESKTOP_REMOTE_URL = $RemoteUrl
    }
    if ($Launch) {
        # The child inherits the URL before the parent environment is restored.
        Start-Process -FilePath $exe -WorkingDirectory $folder | Out-Null
    }
} finally {
    [Environment]::SetEnvironmentVariable('HERMES_DESKTOP_VARIANT', $originalVariant, 'Process')
    [Environment]::SetEnvironmentVariable('HERMES_DESKTOP_REMOTE_URL', $originalRemote, 'Process')
    Set-Location -LiteralPath $originalLocation.Path
}
