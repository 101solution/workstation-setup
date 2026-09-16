# Set and force overwrite of the $HOME variable
Set-Variable HOME "#workFolder#" -Force

# Set the "~" shortcut value for the FileSystem provider
(get-psprovider 'FileSystem').Home = "#workFolder#"
# Skipped when unavailable: endpoint policy can block the unsigned binary.
if (Get-Command carapace -ErrorAction SilentlyContinue) {
    carapace _carapace powershell | Out-String | Invoke-Expression
}
oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\rudolfs-light-cs.omp.json" | Invoke-Expression
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