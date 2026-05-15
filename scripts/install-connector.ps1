# Installs the Microsoft Entra Application Proxy Connector silently.
# Registration with the tenant is NOT performed here -- it requires
# interactive Application Administrator credentials and is run manually
# after the VM is up (see postprovision output for steps).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installerUrl = 'https://download.msappproxy.net/Subscription/d3c8b69d-6bf7-42be-a529-3fe9c2e70c90/Connector/DownloadConnectorInstaller'
$installerPath = "$env:TEMP\AADAppProxyConnectorInstaller.exe"

# Required to satisfy the installer prerequisite check.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'DisableLoopbackCheck' -Value 1 -Type DWord -Force

# Allow TLS1.2 for the download.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

# REGISTERCONNECTOR=false -> install bits only; manual registration follows.
$args = '/q REGISTERCONNECTOR="false" ACCEPTEULA=1'
$proc = Start-Process -FilePath $installerPath -ArgumentList $args -PassThru -Wait
if ($proc.ExitCode -ne 0) {
    throw "Connector installer exited with code $($proc.ExitCode)"
}

Write-Host "Connector binaries installed. Run RegisterConnector.ps1 manually to join the tenant."
