<# 
Microsoft Lab Environment
.File Name
 - InstallHyperV.ps1
 
.What calls this script?
 - This is a PowerShell DSC run as a Custom Script extention called by VMdeploy.json

.What does this script do?  
 - Configures PowerShell to use TLS1.2 to download the NuGet package as per the PowerShell galleries security standards
 
 - Downloads NuGet package provider
    
 - Installs the DscResource and xHyper-V PS modules in support of the upcoming DSC Extenion run in HyperVHostConfig.ps1

 - Installs Hyper-V with all features and management tools; DSC performs any required restart

#>

[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

[DSCLocalConfigurationManager()]
configuration ConfigureLabLcm
{
    node localhost
    {
        Settings
        {
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }
    }
}

$lcmConfigurationPath = Join-Path $env:TEMP 'AzureLabLcm'
ConfigureLabLcm -OutputPath $lcmConfigurationPath | Out-Null
Set-DscLocalConfigurationManager -Path $lcmConfigurationPath -Force

$nuGetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
if (-not $nuGetProvider) {
    Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force | Out-Null
}

$hyperVModule = Get-Module -ListAvailable -Name 'xHyper-V'
if (-not $hyperVModule) {
    Install-Module -Name 'xHyper-V' -Repository PSGallery -Scope AllUsers -Force -AllowClobber
}

if (-not (Get-Module -ListAvailable -Name 'xHyper-V')) {
    throw "The 'xHyper-V' DSC module could not be installed."
}

$hyperVFeature = Get-WindowsFeature -Name Hyper-V
if (-not $hyperVFeature.Installed) {
    $installResult = Install-WindowsFeature -Name Hyper-V `
        -IncludeAllSubFeature `
        -IncludeManagementTools

    if (-not $installResult.Success) {
        throw 'The Hyper-V role installation failed.'
    }

    if ($installResult.RestartNeeded -ne 'No') {
        $stateDirectory = Join-Path $env:ProgramData 'AzureLab'
        New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $stateDirectory 'HyperVRestartRequired') -ItemType File -Force | Out-Null
    }
}