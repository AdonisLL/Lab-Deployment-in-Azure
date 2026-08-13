[CmdletBinding()]
param (
	[ValidatePattern('^[a-zA-Z0-9._()-]{1,90}$')]
	[string] $ResourceGroupName = 'AzureLab',

	[ValidatePattern('^[a-z0-9]+$')]
	[string] $Location = 'centralus',

	[ValidatePattern('^[a-zA-Z0-9._()-]{1,64}$')]
	[string] $BicepDeploymentName = 'AzureLabDeployment',

	[ValidateLength(1, 20)]
	[string] $HyperVHostAdminUserName = 'adminuser',

	[ValidateSet('new', 'existing')]
	[string] $VnetNewOrExisting = 'new',

	[string] $VirtualNetworkName,

	[string] $HyperVHostName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hyperVHostAdminPassword = $env:HYPERV_HOST_ADMIN_PASSWORD
$templateFile = Join-Path $PSScriptRoot 'VMdeploy.bicep'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
	throw 'Azure CLI is required. Install it from https://aka.ms/installazurecliwindows.'
}

$authenticationOutput = & az account get-access-token `
	--resource 'https://management.azure.com/' `
	--only-show-errors `
	--output none 2>&1
if ($LASTEXITCODE -ne 0) {
	$authenticationError = ($authenticationOutput | Out-String).Trim()
	throw "Azure CLI authentication is unavailable or expired. Run 'az logout', then 'az login', and try again. Azure CLI: $authenticationError"
}

& az bicep version *> $null
if ($LASTEXITCODE -ne 0) {
	throw "Azure CLI Bicep support is unavailable. Run 'az bicep install' and try again."
}

if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) {
	throw "Bicep template not found: $templateFile"
}

if ([string]::IsNullOrWhiteSpace($hyperVHostAdminPassword) -or $hyperVHostAdminPassword.Length -lt 8) {
	throw 'Set HYPERV_HOST_ADMIN_PASSWORD to a value containing at least eight characters.'
}

if ($HyperVHostName -and $HyperVHostName.Length -gt 15) {
	throw 'HyperVHostName cannot exceed 15 characters because it is also the Windows computer name.'
}

if ($VnetNewOrExisting -eq 'existing' -and [string]::IsNullOrWhiteSpace($VirtualNetworkName)) {
	throw 'VirtualNetworkName is required when VnetNewOrExisting is existing.'
}

$resourceGroupOutput = & az group exists --name $ResourceGroupName --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
	$resourceGroupError = ($resourceGroupOutput | Out-String).Trim()
	throw "Unable to check resource group '$ResourceGroupName'. Azure CLI: $resourceGroupError"
}
$resourceGroupExists = ($resourceGroupOutput | Select-Object -Last 1).ToString()

if ($resourceGroupExists.Trim() -eq 'true') {
	Write-Host "Resource group '$ResourceGroupName' already exists; continuing."
}
else {
	& az group create --name $ResourceGroupName --location $Location --only-show-errors --output none
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to create resource group '$ResourceGroupName'."
	}
}

if ($VnetNewOrExisting -eq 'new') {
	if ($VirtualNetworkName) {
		$existingVirtualNetworkName = & az network vnet list `
			--resource-group $ResourceGroupName `
			--query "[?name=='$VirtualNetworkName'].name | [0]" `
			--only-show-errors `
			--output tsv
		if ($LASTEXITCODE -ne 0) {
			throw "Unable to check virtual network '$VirtualNetworkName' in resource group '$ResourceGroupName'."
		}
	}
	else {
		$labVirtualNetworks = @(& az network vnet list `
			--resource-group $ResourceGroupName `
			--query "[?tags.Purpose=='LabDeployment'].name" `
			--only-show-errors `
			--output tsv)
		if ($LASTEXITCODE -ne 0) {
			throw "Unable to inspect existing lab virtual networks in resource group '$ResourceGroupName'."
		}
		if ($labVirtualNetworks.Count -gt 1) {
			throw "Multiple lab virtual networks exist in resource group '$ResourceGroupName'. Specify VirtualNetworkName explicitly."
		}
		$existingVirtualNetworkName = $labVirtualNetworks | Select-Object -First 1
	}

	if (-not [string]::IsNullOrWhiteSpace($existingVirtualNetworkName)) {
		$VirtualNetworkName = $existingVirtualNetworkName
		$VnetNewOrExisting = 'existing'
		Write-Host "Virtual network '$VirtualNetworkName' already exists; continuing without replacing it."
	}
}

if ($VnetNewOrExisting -eq 'existing') {
	& az network vnet show --resource-group $ResourceGroupName --name $VirtualNetworkName --only-show-errors --output none
	if ($LASTEXITCODE -ne 0) {
		throw "Virtual network '$VirtualNetworkName' does not exist in resource group '$ResourceGroupName'."
	}

	$vmHostSubnetCount = & az network vnet subnet list `
		--resource-group $ResourceGroupName `
		--vnet-name $VirtualNetworkName `
		--query "[?name=='VMHOST'] | length(@)" `
		--only-show-errors `
		--output tsv
	if ($LASTEXITCODE -ne 0) {
		throw "Unable to inspect the VMHOST subnet in virtual network '$VirtualNetworkName'."
	}

	$bastionSubnetCount = & az network vnet subnet list `
		--resource-group $ResourceGroupName `
		--vnet-name $VirtualNetworkName `
		--query "[?name=='AzureBastionSubnet'] | length(@)" `
		--only-show-errors `
		--output tsv

	if ($LASTEXITCODE -ne 0) {
		throw "Unable to inspect AzureBastionSubnet in virtual network '$VirtualNetworkName'."
	}

	$vmHostSubnetExists = [int] $vmHostSubnetCount -gt 0
	$bastionSubnetExists = [int] $bastionSubnetCount -gt 0
}

$parameterValues = [ordered] @{
	HyperVHostAdminUserName = @{ value = $HyperVHostAdminUserName }
	HyperVHostAdminPassword = @{ value = $hyperVHostAdminPassword }
	vnetNewOrExisting = @{ value = $VnetNewOrExisting }
}

if ($VirtualNetworkName) {
	$parameterValues.virtualNetworkName = @{ value = $VirtualNetworkName }
}

if ($VnetNewOrExisting -eq 'existing') {
	$parameterValues.vmHostSubnetExists = @{ value = $vmHostSubnetExists }
	$parameterValues.bastionSubnetExists = @{ value = $bastionSubnetExists }
}

if ($HyperVHostName) {
	$parameterValues.HyperVHostName = @{ value = $HyperVHostName }
}

$parameterFile = Join-Path ([IO.Path]::GetTempPath()) "azure-lab-$([guid]::NewGuid().ToString('N')).parameters.json"
$parameterDocument = [ordered] @{
	'$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
	contentVersion = '1.0.0.0'
	parameters = $parameterValues
}
[IO.File]::WriteAllText($parameterFile, ($parameterDocument | ConvertTo-Json -Depth 5), [Text.Encoding]::UTF8)

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
$parameterFileAcl = New-Object Security.AccessControl.FileSecurity
$parameterFileAcl.SetOwner($currentUser)
$parameterFileAcl.SetAccessRuleProtection($true, $false)
$parameterFileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
	$currentUser,
	[Security.AccessControl.FileSystemRights]::FullControl,
	[Security.AccessControl.AccessControlType]::Allow
)))
Set-Acl -LiteralPath $parameterFile -AclObject $parameterFileAcl

$deploymentArguments = @(
	'--name', $BicepDeploymentName
	'--resource-group', $ResourceGroupName
	'--template-file', $templateFile
	'--mode', 'Incremental'
	'--parameters'
	"@$parameterFile"
)

try {
	Write-Host "Validating deployment '$BicepDeploymentName'."
	& az deployment group validate @deploymentArguments --only-show-errors --output none
	if ($LASTEXITCODE -ne 0) {
		throw "Validation failed for deployment '$BicepDeploymentName'."
	}

	Write-Host "Deploying '$BicepDeploymentName' in incremental mode."
	& az deployment group create @deploymentArguments --only-show-errors --output none
	if ($LASTEXITCODE -ne 0) {
		throw "Deployment '$BicepDeploymentName' failed."
	}
}
finally {
	Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Deployment '$BicepDeploymentName' completed successfully."