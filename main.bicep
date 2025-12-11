@description('VM name')
param vmName string

@description('Location for resources')
param location string = resourceGroup().location

@description('VM size')
@allowed([
  'Standard_D4s_v5'
  'Standard_D8s_v5'
  'Standard_D16s_v5'
])
param vmSize string = 'Standard_D8s_v5'

@description('Admin username')
param adminUsername string = 'azureuser'

@description('Data disk size in GB')
param dataDiskSizeGB int = 64

@description('Email for failure notifications')
param alertEmail string

@description('Enable Entra ID (Azure AD) SSH login for interactive shell access')
param enableEntraSSH bool = false

@description('Enable SSH access in NSG (required for Entra ID SSH)')
param enableSSHAccess bool = false

@description('Source IP range for SSH access (CIDR notation, e.g., 172.20.0.0/16)')
param sshSourceAddressPrefix string = ''

@description('Short project name for storage account (lowercase, no special chars)')
param projectName string = 'vm'

@description('Storage account name (auto-generated if not specified)')
param storageAccountName string = '${projectName}${uniqueString(resourceGroup().id)}'

@description('Inbound port rules for NSG')
param inboundPorts array = []

@description('Create a public IP address for the VM')
param createPublicIp bool = true

var vnetName = '${vmName}-vnet'
var subnetName = '${vmName}-subnet'
var nsgName = '${vmName}-nsg'
var publicIpName = '${vmName}-pip'
var nicName = '${vmName}-nic'
var osDiskName = '${vmName}-osdisk'
var dataDiskName = '${vmName}-datadisk'
@secure()
@description('Admin password for VM (min 12 chars, must include uppercase, lowercase, number, and special char)')
param adminPassword string

@description('Base64-encoded cloud-init configuration')
param customData string = ''

var actionGroupName = '${vmName}-alerts'
// Short name max 12 chars - use project name or truncate vm name
var actionGroupShortName = length(projectName) <= 8 ? '${projectName}-alrt' : substring(vmName, 0, min(length(vmName), 8))

// Pre-compute custom inbound port rules (for-expressions must be in variable context)
var customInboundRules = [for rule in inboundPorts: {
  name: rule.name
  properties: {
    priority: rule.priority
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: rule.portRange
    sourceAddressPrefixes: rule.sourceAddressPrefixes
    destinationAddressPrefix: '*'
  }
}]

// Network Security Group - Conditional SSH, custom inbound ports
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: concat(
      // SSH rule - Allow or Deny based on enableSSHAccess
      enableSSHAccess && !empty(sshSourceAddressPrefix) ? [
        {
          name: 'AllowSSH'
          properties: {
            priority: 1000
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefix: sshSourceAddressPrefix
            destinationAddressPrefix: '*'
          }
        }
      ] : [
        {
          name: 'DenySSH'
          properties: {
            priority: 1000
            direction: 'Inbound'
            access: 'Deny'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
          }
        }
      ],
      // Custom inbound port rules from parameters
      customInboundRules
    )
  }
}

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// Public IP - Optional, for external access
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = if (createPublicIp) {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: vmName
    }
  }
}

// Network Interface
resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: union(
          {
            subnet: {
              id: vnet.properties.subnets[0].id
            }
            privateIPAllocationMethod: 'Dynamic'
          },
          createPublicIp ? {
            publicIPAddress: {
              id: publicIp.id
            }
          } : {}
        )
      }
    ]
  }
}

// Storage Account for diagnostics
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

// Virtual Machine
resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: vmName
  location: location
  identity: enableEntraSSH ? {
    type: 'SystemAssigned'
  } : null
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: !empty(customData) ? customData : null
      linuxConfiguration: {
        disablePasswordAuthentication: false
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            rebootSetting: 'IfRequired'
            bypassPlatformSafetyChecksOnUserSchedule: false
          }
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          name: dataDiskName
          diskSizeGB: dataDiskSizeGB
          lun: 0
          createOption: 'Empty'
          caching: 'ReadOnly'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: storageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

// Auto-shutdown (optional cost savings)
resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  properties: {
    status: 'Disabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: '0200'
    }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
  }
}

// Entra ID (Azure AD) SSH Login Extension - enables Azure AD authentication for SSH
resource aadSSHExtension 'Microsoft.Compute/virtualMachines/extensions@2023-07-01' = if (enableEntraSSH) {
  parent: vm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

// Action Group for alerts
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [
      {
        name: 'admin'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// VM availability alert
resource vmAvailabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${vmName}-availability'
  location: 'global'
  properties: {
    description: 'Alert when VM availability drops'
    severity: 1
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'VMAvailability'
          metricName: 'VmAvailabilityMetric'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// High CPU alert (indicates potential issues)
resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${vmName}-high-cpu'
  location: 'global'
  properties: {
    description: 'Alert when CPU exceeds 90% for 15 minutes'
    severity: 2
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCPU'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 90
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// Low memory alert
resource memoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${vmName}-low-memory'
  location: 'global'
  properties: {
    description: 'Alert when available memory is low'
    severity: 2
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'LowMemory'
          metricName: 'Available Memory Bytes'
          operator: 'LessThan'
          threshold: 2147483648
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

output vmPublicIp string = createPublicIp ? publicIp.properties.ipAddress : ''
output vmFqdn string = createPublicIp ? publicIp.properties.dnsSettings.fqdn : ''
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output hasPublicIp bool = createPublicIp
output serialConsoleUrl string = 'https://portal.azure.com/#@/resource${vm.id}/serialConsole'
output runCommandUrl string = 'https://portal.azure.com/#@/resource${vm.id}/runCommand'
output vmResourceId string = vm.id
output entraSSHEnabled bool = enableEntraSSH
output sshAccessEnabled bool = enableSSHAccess
output adminUsername string = adminUsername
output storageAccountName string = storageAccount.name
