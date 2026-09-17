# Set and force overwrite of the $HOME variable
Set-Variable HOME "#workFolder#" -Force

# Set the "~" shortcut value for the FileSystem provider
(get-psprovider 'FileSystem').Home = "#workFolder#"
# Skipped when unavailable: endpoint policy can block the unsigned binary.
if (Get-Command carapace -ErrorAction SilentlyContinue) {
    carapace _carapace powershell | Out-String | Invoke-Expression
}
# oh-my-posh may be installed as an MSIX package, in which case `oh-my-posh` on PATH is a 0-byte
# app-execution-alias stub. Its generated init script re-resolves that bare name through
# Process.Start, which cannot launch a stub: it fails with "The file cannot be accessed by the
# system" and pops a modal App Installer dialog. Putting the package folder first on PATH makes the
# bare name resolve to the real exe. Passing a full path to `init` is not enough - the generated
# script hardcodes the bare name.
# A plain exe is preferred where one exists: some machines take 10+ seconds per MSIX activation,
# and oh-my-posh runs the exe on every prompt render.
$ompBin = Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\bin'
if (Test-Path -LiteralPath (Join-Path $ompBin 'oh-my-posh.exe')) {
    $env:PATH = "$ompBin;$env:PATH"
} else {
    $ompPkg = Get-AppxPackage -Name 'ohmyposh.cli' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($ompPkg -and (Test-Path -LiteralPath (Join-Path $ompPkg.InstallLocation 'oh-my-posh.exe'))) {
        $env:PATH = "$($ompPkg.InstallLocation);$env:PATH"
    }
}
# The MSIX build never sets POSH_THEMES_PATH, so mirror the fallback config-workstation.ps1 used
# when it deployed the theme. Without this the config path resolves to the drive root and the
# custom prompt silently falls back to a default.
$poshThemes = $env:POSH_THEMES_PATH
if ([string]::IsNullOrWhiteSpace($poshThemes)) {
    $poshThemes = Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\themes'
}
$poshTheme = Join-Path $poshThemes 'rudolfs-light-cs.omp.json'
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    if (Test-Path -LiteralPath $poshTheme) { oh-my-posh init pwsh --config $poshTheme | Invoke-Expression }
    else { oh-my-posh init pwsh | Invoke-Expression }
}
# Guarded like carapace: a machine without zoxide should still start a clean shell.
# Must stay *after* the oh-my-posh init: zoxide hooks directory tracking by wrapping whatever
# `prompt` is defined at that moment, so initialising it first means oh-my-posh overwrites the hook.
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

Import-Module PSReadLine

# Shows navigable menu of all options when hitting Tab
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

# Autocompleteion for Arrow keys
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

Set-PSReadLineOption -ShowToolTips
# Prediction needs a real console. Agent harnesses (Claude Code, Codex) run commands with
# redirected stdio, where PSReadLine emits "PredictionSource is not supported" on every command.
if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    Set-PSReadLineOption -PredictionSource History
}

# PowerShell parameter completion shim for the dotnet CLI
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)
        dotnet complete --position $cursorPosition "$wordToComplete" | ForEach-Object {
           [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

# Bare `docker` targets the WSL2 Linux daemon on 2375; the Windows daemon is a separate context on
# 2378. See docker-ce/README.md.
function docker-w { docker -c win @args }

# PATH auditing (Test-PathHealth / Repair-PathHealth), deployed next to this profile by
# config-workstation.ps1. Guarded exactly like carapace and zoxide above: a machine where the file
# did not land must still start a clean shell, since a broken profile breaks every session.
# The ConstrainedLanguage test matters because dot-sourcing a FullLanguage script throws under the
# restricted language mode some agent sandboxes use, and these functions are interactive-only.
$pathHealth = Join-Path $PSScriptRoot 'path-health.ps1'
if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage' -and (Test-Path -LiteralPath $pathHealth)) {
    . $pathHealth
    # String-only check, no disk I/O, so it is cheap enough to run on every shell start.
    if (-not (Test-PathHealth -Quiet)) {
        Write-Warning "PATH health issues detected - run Test-PathHealth for details."
    }
}

# Optional Azure/ADO/Terraform helpers from the separate `dev-scripts` repo
# (ADO MinRes-Infra/NextDigital). That repo owns which libraries load, via its own
# profile-fragment.ps1 - this profile only decides whether to ask. Setup does not clone it, so most
# machines will not have it and the Test-Path is the normal case, not an edge case.
# $HOME is the work folder by the time we get here (set at the top of this file), so the default
# follows -defaultWorkFolder instead of hardcoding a drive path.
$devScripts = if ($env:DEVSCRIPTS) { $env:DEVSCRIPTS } else { Join-Path $HOME 'MinRes-Infra\nextdigital\dev-scripts' }
$devFragment = Join-Path $devScripts 'profile-fragment.ps1'
if (Test-Path -LiteralPath $devFragment) { . $devFragment }