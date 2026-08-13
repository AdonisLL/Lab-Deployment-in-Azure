@description('Local administrator username for the Hyper-V host.')
@minLength(1)
@maxLength(20)
param HyperVHostAdminUserName string 

@description('Local administrator password for the Hyper-V host.')
@minLength(8)
@secure()
param HyperVHostAdminPassword string

@description('Azure region for all lab resources.')
param location string = resourceGroup().location

@description('Name of the Hyper-V host. Defaults to a deterministic, resource-group-specific name.')
@minLength(1)
@maxLength(15)
param HyperVHostName string = take('hv${uniqueString(resourceGroup().id)}', 15)

@description('Specify whether to provision a new virtual network or deploy into an existing virtual network.')
@allowed([
  'new'
  'existing'
])
param vnetNewOrExisting string

@description('Virtual network name. For new deployments, the default is deterministic and unique to the resource group.')
@minLength(2)
@maxLength(64)
param virtualNetworkName string = vnetNewOrExisting == 'new'
  ? 'lab-vnet-${uniqueString(resourceGroup().id)}'
  : 'OnPremVNET'

@description('Changes on each deployment so VM extensions apply updated configuration packages.')
param deploymentRunId string = utcNow('u')

@description('Indicates that the VM host subnet already exists and must not be modified.')
param vmHostSubnetExists bool = false

@description('Indicates that AzureBastionSubnet already exists and must not be modified.')
param bastionSubnetExists bool = false

var OnPremVNETPrefix = '10.0.0.0/16'
var OnPremVNETSubnet1Name = 'VMHOST'
var OnPremVNETSubnet1Prefix = '10.0.0.0/24'
var OnPremVNETBastionSubnetName = 'AzureBastionSubnet'
var OnPremVNETBastionSubnetPrefix = '10.0.1.0/24'
var HyperVHostImagePublisher = 'MicrosoftWindowsServer'
var HyperVHostImageOffer = 'WindowsServer'
var HyperVHostWindowsOSVersion = '2022-datacenter-g2'
var HyperVHostVmSize = 'Standard_D8s_v7'
var HyperVHost_NSG_Name = '${HyperVHostName}-NSG'
var HyperVHostNicName = '${HyperVHostName}-NIC'
var BastionNsgName = '${BastionHostName}-NSG'
var BastionHostName = '${HyperVHostName}-bastion'
var Bastion_PUBIPName = '${BastionHostName}-PIP'
var HyperVHostConfigURL = 'https://github.com/weeyin83/Lab-Deployment-in-Azure/blob/main/HyperVHostConfig.zip?raw=true'
var HyperVHostInstallHyperVScriptFolder = '.'
var HyperVHostInstallHyperVScriptFileName = 'InstallHyperV.ps1'
var HyperVHostInstallHyperVURL = 'https://raw.githubusercontent.com/weeyin83/Lab-Deployment-in-Azure/main/InstallHyperV.ps1'

resource HyperVHost_NSG 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: HyperVHost_NSG_Name
  location: location
  tags: {
    Purpose: 'LabDeployment'
  }
  properties: {
    securityRules: [
      {
        name: 'RDP_Access'
        properties: {
          description: 'Allow RDP'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: 'virtualnetwork'
          destinationAddressPrefix: OnPremVNETSubnet1Prefix
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: BastionNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInBound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationPortRange: '443'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowGatewayManagerInBound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'GatewayManager'
          destinationPortRange: '443'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowLoadBalancerInBound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationPortRange: '443'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowBastionHostCommunicationInBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 130
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowSshRdpOutBound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'AllowAzureCloudCommunicationOutBound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '443'
          destinationAddressPrefix: 'AzureCloud'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'AllowBastionHostCommunicationOutBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 120
          direction: 'Outbound'
        }
      }
      {
        name: 'AllowGetSessionInformationOutBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: [
            '80'
            '443'
          ]
          access: 'Allow'
          priority: 130
          direction: 'Outbound'
        }
      }
      {
        name: 'DenyAllOutBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

resource OnPremVNET 'Microsoft.Network/virtualNetworks@2024-07-01' = if (vnetNewOrExisting == 'new') {
  name: virtualNetworkName
  location: location
  tags: {
    Purpose: 'LabDeployment'
  }
  properties: {
    addressSpace: {
      addressPrefixes: [
        OnPremVNETPrefix
      ]
    }
    subnets: [
      {
        name: OnPremVNETSubnet1Name
        properties: {
          addressPrefix: OnPremVNETSubnet1Prefix
          networkSecurityGroup: {
            id: HyperVHost_NSG.id
          }
        }
      }
      {
        name: OnPremVNETBastionSubnetName
        properties: {
          addressPrefix: OnPremVNETBastionSubnetPrefix
          networkSecurityGroup: {
            id: bastionNsg.id
          }
        }
      }
    ]
  }
}

// Existing child resources are updated in place when they are already present.
resource existingVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-07-01' existing = if (vnetNewOrExisting == 'existing') {
  name: virtualNetworkName
}

resource existingVmHostSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = if (vnetNewOrExisting == 'existing' && vmHostSubnetExists) {
  parent: existingVirtualNetwork
  name: OnPremVNETSubnet1Name
}

resource newVmHostSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = if (vnetNewOrExisting == 'existing' && !vmHostSubnetExists) {
  parent: existingVirtualNetwork
  name: OnPremVNETSubnet1Name
  properties: {
    addressPrefix: OnPremVNETSubnet1Prefix
    networkSecurityGroup: {
      id: HyperVHost_NSG.id
    }
  }
}

resource existingBastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = if (vnetNewOrExisting == 'existing' && bastionSubnetExists) {
  parent: existingVirtualNetwork
  name: OnPremVNETBastionSubnetName
}

resource newBastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = if (vnetNewOrExisting == 'existing' && !bastionSubnetExists) {
  parent: existingVirtualNetwork
  name: OnPremVNETBastionSubnetName
  properties: {
    addressPrefix: OnPremVNETBastionSubnetPrefix
    networkSecurityGroup: {
      id: bastionNsg.id
    }
  }
}

resource Bastion_PUBIP 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: Bastion_PUBIPName
  sku:{
    name: 'Standard'
  }
  location: location
  tags: {
    Purpose: 'LabDeployment'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: BastionHostName
    }
  }
}

resource bastionHost 'Microsoft.Network/bastionHosts@2024-07-01' = {
  name: BastionHostName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: vnetNewOrExisting == 'new'
              ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, OnPremVNETBastionSubnetName)
              : (bastionSubnetExists ? existingBastionSubnet.id : newBastionSubnet.id)
          }
          publicIPAddress: {
            id: Bastion_PUBIP.id
          }
        }
      }
    ]
  }
  dependsOn: [
    OnPremVNET
  ]
}

resource HyperVHostNic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: HyperVHostNicName
  location: location
  tags: {
    Purpose: 'LabDeployment'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnetNewOrExisting == 'new'
              ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, OnPremVNETSubnet1Name)
              : (vmHostSubnetExists ? existingVmHostSubnet.id : newVmHostSubnet.id)
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: HyperVHost_NSG.id
    }
  }
  dependsOn: [
    OnPremVNET
  ]
}

resource HyperVHost 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: HyperVHostName
  location: location
  tags: {
    Purpose: 'LabDeployment'
  }
  properties: {
    hardwareProfile: {
      vmSize: HyperVHostVmSize
    }
    osProfile: {
      computerName: HyperVHostName
      adminUsername: HyperVHostAdminUserName
      adminPassword: HyperVHostAdminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: HyperVHostImagePublisher
        offer: HyperVHostImageOffer
        sku: HyperVHostWindowsOSVersion
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 500
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 512
          caching: 'None'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: HyperVHostNic.id
        }
      ]
    }
  }
}

resource HyperVHostName_InstallHyperV 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: HyperVHost
  name: 'InstallHyperV'
  location: location
  tags: {
    displayName: 'Install Hyper-V'
  }
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deploymentRunId
    settings: {
      fileUris: [
        HyperVHostInstallHyperVURL
      ]
      commandToExecute: 'powershell -NoProfile -ExecutionPolicy Bypass -File ${HyperVHostInstallHyperVScriptFolder}/${HyperVHostInstallHyperVScriptFileName}'
    }
  }
}

resource HyperVHostName_HyperVHostConfig 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: HyperVHost
  name: 'HyperVHostConfig'
  location: location
  tags: {
    displayName: 'HyperVHostConfig'
  }
  properties: {
    publisher: 'Microsoft.PowerShell'
    type: 'DSC'
    typeHandlerVersion: '2.9'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deploymentRunId
    settings: {
      configuration: {
        url: concat(HyperVHostConfigURL)
        script: 'HyperVHostConfig.ps1'
        function: 'Main'
      }
      configurationArguments: {
        nodeName: HyperVHostName
      }
    }
  }
  dependsOn: [
    HyperVHostName_InstallHyperV
  ]
}

