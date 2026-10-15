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
Import-Module PSReadLine

# Shows navigable menu of all options when hitting Tab
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

# Autocompleteion for Arrow keys
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

Set-PSReadLineOption -ShowToolTips
Set-PSReadLineOption -PredictionSource History

# PowerShell parameter completion shim for the dotnet CLI
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)
        dotnet complete --position $cursorPosition "$wordToComplete" | ForEach-Object {
           [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}