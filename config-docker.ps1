[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $dockerVersion = "20.10.23"
)
$ctFeatureResult = Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart -WarningAction SilentlyContinue
if($ctFeatureResult.RestartNeeded){
    Restart-Computer -Force
}
$hvFeatureResult = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -WarningAction SilentlyContinue
if($hvFeatureResult.RestartNeeded){
    Restart-Computer -Force
}

curl.exe -o docker.zip -LO https://download.docker.com/win/static/stable/x86_64/docker-$dockerVersion.zip 
Expand-Archive docker.zip -DestinationPath C:\
[Environment]::SetEnvironmentVariable("Path", "$($env:path);C:\docker", [System.EnvironmentVariableTarget]::Machine)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
dockerd --register-service
Start-Service docker
docker run hello-world