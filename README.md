# Workstation Configuration
This is PowerShell script to set up workstation with needed software
1. Open PowerShell window in Administrator mode
1. Goto the folder where the script copied to
1. update choco-packages.json file to your need
1. run (role can be dev, devops or qa)
    > powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role dev
## Configure Windows Terminal (Optional)
Please following the article to config your windows terminal <br>
[Windows Terminal PowerShell Prompt](https://www.hanselman.com/blog/my-ultimate-powershell-prompt-with-oh-my-posh-and-the-windows-terminal)
## Configure powershell history (Optional)
Please follow the article below to configure powershell command history <br/>
[Powershell PSReadLine](https://www.hanselman.com/blog/you-should-be-customizing-your-powershell-prompt-with-psreadline)

## How to update Powershell Profile (Optional)
The easy way is run the following command, it will open the default profile
> code $PROFILE

an example of profile is as below

```
# Set and force overwrite of the $HOME variable
Set-Variable HOME "C:\Repos\" -Force

# Set the "~" shortcut value for the FileSystem provider
(get-psprovider 'FileSystem').Home = "C:\Repos\"
Import-Module Posh-Git
Import-Module oh-my-posh
Set-PoshPrompt -Theme rudolfs-light # choose your prefer theme https://ohmyposh.dev/docs/themes

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

```