<# 
Microsoft Lab Environment - Azure Backup
.File Name
 - HyperVHostConfig.ps1
 
.What calls this script?
 - 

.What does this script do?  
 - Creates an Internal Switch in Hyper-V called "NatSwitch"
    
 - Downloads an images of several servers for the lab environment

 - Repartitions the OS disk to 400GB in size

 - Add a new IP address to the Internal Network for Hyper-V attached to the NATSwitch

 - Creates a NAT Network on 192.168.0.0/24

 - Creates the Virtual Machines in Hyper-V

 - Issues a Start Command for the new VMs
#>

Configuration Main
{
	Param ( [string] $nodeName )

	Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'xHyper-V'

	node $nodeName
  	{
		Script CompletePendingHyperVRestart
		{
			GetScript =
			{
				@{ Result = (Test-Path -LiteralPath "$env:ProgramData\AzureLab\HyperVRestartRequired") }
			}

			TestScript =
			{
				-not (Test-Path -LiteralPath "$env:ProgramData\AzureLab\HyperVRestartRequired")
			}

			SetScript =
			{
				Remove-Item -LiteralPath "$env:ProgramData\AzureLab\HyperVRestartRequired" -Force
				$global:DSCMachineStatus = 1
			}
		}

		# Ensures a VM with default settings
        xVMSwitch InternalSwitch
        {
            Ensure         = 'Present'
            Name           = 'NatSwitch'
            Type           = 'Internal'
			DependsOn      = '[Script]CompletePendingHyperVRestart'
        }
		
		Script ConfigureHyperV
    	{
			DependsOn = '[xVMSwitch]InternalSwitch'

			GetScript = 
			{
				$vmStates = Get-VM -Name 'AD01', 'FS01', 'SQL01', 'WEB01', 'WEB02' -ErrorAction SilentlyContinue |
					Select-Object Name, State
				@{ Result = ($vmStates | ConvertTo-Json -Compress) }
			}	
		
			TestScript = 
			{
				$requiredVmNames = @('AD01', 'FS01', 'SQL01', 'WEB01', 'WEB02')
				$existingVms = @(Get-VM -Name $requiredVmNames -ErrorAction SilentlyContinue)
				$allVmsRunning = $existingVms.Count -eq $requiredVmNames.Count -and
					@($existingVms | Where-Object State -ne 'Running').Count -eq 0
				$nat = Get-NetNat -Name 'NestedVMNATnetwork' -ErrorAction SilentlyContinue
				$natExists = $null -ne $nat -and $nat.InternalIPInterfaceAddressPrefix -eq '192.168.0.0/24'
				$gatewayExists = $null -ne (Get-NetIPAddress `
					-InterfaceAlias 'vEthernet (NatSwitch)' `
					-IPAddress '192.168.0.1' `
					-PrefixLength 24 `
					-ErrorAction SilentlyContinue)

				return $allVmsRunning -and $natExists -and $gatewayExists
        	}	
		
			SetScript =
			{
				$ErrorActionPreference = 'Stop'
				$zipDownload = 'https://techielassblogstorage.blob.core.windows.net/azurelab/HyperVLabVMs.zip'
				$dataDriveLetter = 'F'
				$expectedDataDiskSize = 512GB
				$downloadFolder = "${dataDriveLetter}:\Downloads"
				$downloadedFile = Join-Path $downloadFolder 'HyperVLabVMs.zip'
				$vmFolder = "${dataDriveLetter}:\VM"
				$vmDefinitions = @(
					@{ Name = 'AD01'; Memory = 2GB; VhdPath = (Join-Path $vmFolder 'AD01.vhdx') }
					@{ Name = 'FS01'; Memory = 2GB; VhdPath = (Join-Path $vmFolder 'FS01.vhdx') }
					@{ Name = 'SQL01'; Memory = 8GB; VhdPath = (Join-Path $vmFolder 'SQL01.vhdx') }
					@{ Name = 'WEB01'; Memory = 2GB; VhdPath = (Join-Path $vmFolder 'WEB01.vhdx') }
					@{ Name = 'WEB02'; Memory = 2GB; VhdPath = (Join-Path $vmFolder 'WEB02.vhdx') }
				)

				$dataVolume = Get-Volume -DriveLetter $dataDriveLetter -ErrorAction SilentlyContinue
				if ($null -ne $dataVolume -and $dataVolume.FileSystemLabel -ne 'AzureLabData') {
					throw "Drive ${dataDriveLetter}: is already in use and is not the Azure lab data disk."
				}
				if ($null -eq $dataVolume) {
					$dataDisks = @()
					for ($attempt = 1; $attempt -le 30 -and $dataDisks.Count -eq 0; $attempt++) {
						$dataDisks = @(Get-Disk | Where-Object {
							-not $_.IsBoot -and -not $_.IsSystem -and
							[Math]::Abs($_.Size - $expectedDataDiskSize) -le 1GB
						})
						if ($dataDisks.Count -eq 0) {
							Start-Sleep -Seconds 2
						}
					}
					if ($dataDisks.Count -eq 0) {
						throw 'The managed Azure lab data disk was not available after 60 seconds.'
					}
					if ($dataDisks.Count -ne 1) {
						throw "Expected one 512 GiB non-system data disk, but found $($dataDisks.Count)."
					}

					$dataDisk = $dataDisks[0]
					if ($dataDisk.IsOffline) {
						Set-Disk -Number $dataDisk.Number -IsOffline $false
					}
					if ($dataDisk.IsReadOnly) {
						Set-Disk -Number $dataDisk.Number -IsReadOnly $false
					}
					if ($dataDisk.PartitionStyle -eq 'RAW') {
						Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT
					}

					$dataPartitions = @(Get-Partition -DiskNumber $dataDisk.Number -ErrorAction SilentlyContinue | Where-Object Type -eq 'Basic')
					if ($dataPartitions.Count -eq 0) {
						$dataPartition = New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -DriveLetter $dataDriveLetter
					}
					elseif ($dataPartitions.Count -eq 1) {
						$dataPartition = $dataPartitions[0]
					}
					else {
						throw "The Azure lab data disk has $($dataPartitions.Count) data partitions; expected one."
					}
					if ($dataPartition.DriveLetter -ne $dataDriveLetter) {
						Set-Partition -DiskNumber $dataDisk.Number -PartitionNumber $dataPartition.PartitionNumber -NewDriveLetter $dataDriveLetter
						$dataPartition = Get-Partition -DiskNumber $dataDisk.Number -PartitionNumber $dataPartition.PartitionNumber
					}

					$dataVolume = $dataPartition | Get-Volume -ErrorAction SilentlyContinue
					if ([string]::IsNullOrWhiteSpace($dataVolume.FileSystem)) {
						$dataPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'AzureLabData' -Confirm:$false | Out-Null
					}
					elseif ($dataVolume.FileSystem -ne 'NTFS' -or $dataVolume.FileSystemLabel -ne 'AzureLabData') {
						throw 'The managed Azure lab data disk contains an unexpected filesystem or label.'
					}
				}
				for ($attempt = 1; $attempt -le 30 -and -not (Test-Path -LiteralPath "${dataDriveLetter}:\" -PathType Container); $attempt++) {
					Start-Sleep -Seconds 2
				}
				if (-not (Test-Path -LiteralPath "${dataDriveLetter}:\" -PathType Container)) {
					throw "The Azure lab data volume was not available as drive ${dataDriveLetter}: after 60 seconds."
				}

				New-Item -Path $downloadFolder, $vmFolder -ItemType Directory -Force | Out-Null
				$missingVhds = @($vmDefinitions | Where-Object { -not (Test-Path -LiteralPath $_.VhdPath -PathType Leaf) })
				if ($missingVhds.Count -gt 0) {
					Invoke-WebRequest -Uri $zipDownload -OutFile $downloadedFile -UseBasicParsing
					Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
					$archive = [IO.Compression.ZipFile]::OpenRead($downloadedFile)
					$archive.Dispose()
					Expand-Archive -LiteralPath $downloadedFile -DestinationPath $vmFolder -Force
				}

				$missingVhds = @($vmDefinitions | Where-Object { -not (Test-Path -LiteralPath $_.VhdPath -PathType Leaf) })
				if ($missingVhds.Count -gt 0) {
					throw "Missing required VHD files: $($missingVhds.Name -join ', ')."
				}

				$natAdapter = $null
				for ($attempt = 1; $attempt -le 30 -and $null -eq $natAdapter; $attempt++) {
					$natAdapter = Get-NetAdapter -Name 'vEthernet (NatSwitch)' -ErrorAction SilentlyContinue
					if ($null -eq $natAdapter) {
						Start-Sleep -Seconds 2
					}
				}

				if ($null -eq $natAdapter) {
					throw "The 'NatSwitch' network adapter was not available after 60 seconds."
				}

				$gatewayAddress = Get-NetIPAddress -InterfaceAlias $natAdapter.Name -IPAddress '192.168.0.1' -ErrorAction SilentlyContinue
				if ($null -ne $gatewayAddress -and $gatewayAddress.PrefixLength -ne 24) {
					$gatewayAddress | Remove-NetIPAddress -Confirm:$false
					$gatewayAddress = $null
				}
				if ($null -eq $gatewayAddress) {
					New-NetIPAddress -IPAddress '192.168.0.1' -PrefixLength 24 -InterfaceAlias $natAdapter.Name | Out-Null
				}

				$nat = Get-NetNat -Name 'NestedVMNATnetwork' -ErrorAction SilentlyContinue
				if ($null -ne $nat -and $nat.InternalIPInterfaceAddressPrefix -ne '192.168.0.0/24') {
					$nat | Remove-NetNat -Confirm:$false
					$nat = $null
				}
				if ($null -eq $nat) {
					New-NetNat -Name 'NestedVMNATnetwork' -InternalIPInterfaceAddressPrefix '192.168.0.0/24' | Out-Null
				}

				foreach ($vmDefinition in $vmDefinitions) {
					if (-not (Get-VM -Name $vmDefinition.Name -ErrorAction SilentlyContinue)) {
						New-VM -Name $vmDefinition.Name `
							-MemoryStartupBytes $vmDefinition.Memory `
							-BootDevice VHD `
							-VHDPath $vmDefinition.VhdPath `
							-Path $vmFolder `
							-Generation 1 `
							-SwitchName 'NatSwitch' | Out-Null
					}

					if ((Get-VM -Name $vmDefinition.Name).State -ne 'Running') {
						Start-VM -Name $vmDefinition.Name | Out-Null
					}
				}
			}
		}	
  	}
}