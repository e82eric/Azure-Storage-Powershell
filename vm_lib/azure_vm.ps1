param(
	$workingDirectory = (Resolve-Path .\).Path,
	$restLibDir = (Resolve-Path "$workingDirectory\..\lib").Path,
	$adalLibDir = (Resolve-Path "$workingDirectory\..\libs").Path
)

. "$restLibDir\management_rest_client.ps1" $restLibDir
. "$restLibDir\adal_authentication_patcher.ps1" $adalLibDir
. "$restLibDir\shared_access_signature_provider.ps1" $restLibDir
. "$restLibDir\blob_storage_client.ps1" $restLibDir

$ErrorActionPreference = "stop"

function new_azure_vm (
	$name,
	$adminUser,
	$workingDirectory,
	$installersDirectory,
	$isoDrive,
	$storageAccount,
	$installersContainer,
	$instanceSize,
	$affinityGroup,
	$serviceName,
	$deploymentName,
	$network,
	$subnet,
	$libDir,
	$installers,
	$subscriptionId,
	$subscriptionAdTenantId,
	$vpnSubnet) {
	$serviceName = $name;
	$deploymentName = "$($serviceName)deployment"

	$restClient = new_subscription_management_rest_client_with_adal $subscriptionId $subscriptionAdTenantId

	$storageKeysResult = $restClient.Request(@{ Verb = "GET"; Resource = "services/storageservices/$storageAccount/keys"; OnResponse = $parse_xml })
	$storageAccountKey = $storageKeysResult.StorageService.StorageServiceKeys.Secondary

	$obj = new_vm_base $name $installersDirectory $isoDrive
	$obj | Add-Member -Type NoteProperty StorageAccount $storageAccount
	$obj | Add-Member -Type NoteProperty StorageAccountKey $storageAccountKey
	$obj | Add-Member -Type NoteProperty InstallersContainer $installersContainer
	$obj | Add-Member -Type NoteProperty InstanceSize $instanceSize
	$obj | Add-Member -Type NoteProperty Network $network
	$obj | Add-Member -Type NoteProperty Subnet $subnet
	$obj | Add-Member -Type NoteProperty ServiceName $serviceName
	$obj | Add-Member -Type NoteProperty DeploymentName $deploymentName
	$obj | Add-Member -Type NoteProperty AffinityGroup $affinityGroup;
	$obj | Add-Member -Type NoteProperty RestClient $restClient;
	$obj | Add-Member -Type NoteProperty VpnSubnet $vpnSubnet;

	Write-Host $obj

	$obj | Add-Member -Type ScriptMethod _createService { 
		$label =  [System.Convert]::ToBase64String([System.Text.Encoding]::UNICODE.GetBytes($this.ServiceName))
		$serviceDef = "<?xml version=`"1.0`" encoding=`"utf-8`"?>
		<CreateHostedService xmlns=`"http://schemas.microsoft.com/windowsazure`">
		  <ServiceName>$($this.ServiceName)</ServiceName>
		  <Label>$label</Label>
		  <Description></Description>
		  <AffinityGroup>$($this.AffinityGroup)</AffinityGroup>
		</CreateHostedService>"
		$this.RestClient.ExecuteOperation("POST", "services/hostedservices", $serviceDef)
	}
	$obj | Add-Member -Type ScriptMethod  _validateInstallers {
		$blobClient = new_blob_storage_client $this.StorageAccount $this.StorageAccountKey

		$blobsXml = $blobClient.Request(@{ Verb = "GET"; Resource = "$($this.InstallersContainer)`?restype=container&comp=list"; ProcessResponse = $parse_xml })
		$blobs = $blobsXml.EnumerationResults.Blobs.Blob

		Write-Host "start validating installers"
		$this.Installers.GetEnumerator() | % {
			$installer = $_.Value 
			$blob = $blobs | ? { $_.Name -eq $installer }

			if($null -eq $blob) {
				throw "could not find $installer" 
			} else {
				Write-Host "found $installer"
			}
		}
		Write-Host "done validating installers"
	}
	$obj | Add-Member -Type ScriptMethod _createVm {
		$this._createService()
		$imagesResult = $this.RestClient.Request(@{ Verb = "GET"; Resource = "services/images"; OnResponse = $parse_xml; Version="2013-08-01" })
		$imageName = ($imagesResult.Images.OsImage | ? { $_.Category -eq "Microsoft Windows Server Group" -And $_.Label-Match "Windows Server 2008 R2 SP1" } | Sort { $_.PublishedDate } | Select -Last 1).Name
		$roleDef = "<RoleName>$($this.Name)</RoleName>
		<RoleType>PersistentVMRole</RoleType>   
		<ConfigurationSets>
			<ConfigurationSet>
				<ConfigurationSetType>NetworkConfiguration</ConfigurationSetType>
				<InputEndpoints>
					<InputEndpoint>
						<LocalPort>3389</LocalPort>
						<Name>RemoteDesktop</Name>
						<Protocol>tcp</Protocol>
						<EnableDirectServerReturn>false</EnableDirectServerReturn>
						<EndpointAcl>
							<Rules>
								<Rule>
									<Order>1</Order>
									<Action>permit</Action>
									<RemoteSubnet>$($this.VpnSubnet)</RemoteSubnet>
									<Description>Permit Point to Site VPN</Description>
								</Rule>
							</Rules>
						</EndpointAcl>
					</InputEndpoint>
					<InputEndpoint>
						<LocalPort>5986</LocalPort>
						<Name>WinRmHTTPs</Name>
						<Protocol>tcp</Protocol>
						<EnableDirectServerReturn>false</EnableDirectServerReturn>
						<EndpointAcl>
							<Rules>
								<Rule>
									<Order>1</Order>
									<Action>permit</Action>
									<RemoteSubnet>$($this.VpnSubnet)</RemoteSubnet>
									<Description>Permit Point to Site VPN</Description>
								</Rule>
							</Rules>
						</EndpointAcl>
					</InputEndpoint>
				</InputEndpoints>
				<StoredCertificateSettings />
			</ConfigurationSet>
			<ConfigurationSet>
				<ConfigurationSetType>WindowsProvisioningConfiguration</ConfigurationSetType>
				<InputEndpoints />
				<SubnetNames>
				    <SubnetName>$($this.SubNet)</SubnetName>
				</SubnetNames>
				<ComputerName>$($this.Name)</ComputerName>
				<AdminPassword>$($this.AdminUser.Password.PlainText)</AdminPassword>
				<ResetPasswordOnFirstLogon>false</ResetPasswordOnFirstLogon>
				<EnableAutomaticUpdates>true</EnableAutomaticUpdates>
				<StoredCertificateSettings />
				<WinRM>
					<Listeners>
						<Listener>
							<Protocol>Https</Protocol>
						</Listener>
					</Listeners>
				</WinRM>
				<AdminUsername>$($this.AdminUser.Name)</AdminUsername>
			</ConfigurationSet>
		</ConfigurationSets>
		<DataVirtualHardDisks />
		<Label>$($this.Name)</Label>
		<OSVirtualHardDisk>
		<MediaLink>https://$($this.StorageAccount).blob.core.windows.net/vhds/$($vmName)_OS.vhd</MediaLink>
		<SourceImageName>$imageName</SourceImageName>
		</OSVirtualHardDisk>
		<RoleSize>$($this.InstanceSize)</RoleSize>"
		
		$vmDef = "<Deployment xmlns=`"http://schemas.microsoft.com/windowsazure`" xmlns:i=`"http://www.w3.org/2001/XMLSchema-instance`">
			<Name>$($this.DeploymentName)</Name>
			<DeploymentSlot>Production</DeploymentSlot>
			<Label>$($this.DeploymentName)</Label>      
			<RoleList>
				<Role>
					$roleDef
				</Role>
		  </RoleList>
		  <VirtualNetworkName>$($this.Network)</VirtualNetworkName>
		</Deployment>"
	
		Write-Host $obj
		Write-Host $vmDef
		$this.RestClient.ExecuteOperation("POST","services/hostedservices/$($this.ServiceName)/deployments", $vmDef)
		$this._waitForBoot()

	}
	$obj | Add-Member -Type ScriptMethod _setWinRmUri {
		$roleResult = $this.RestClient.Request(@{ Verb = "GET"; Resource = "services/hostedservices/$($this.ServiceName)/deployments/$($this.DeploymentName)/roles/$($this.Name)"; OnResponse = $parse_xml })
		$deploymentResult = $this.RestClient.Request(@{ Verb = "GET"; Resource = "services/hostedservices/$($this.ServiceName)/deployments/$($this.DeploymentName)"; OnResponse = $parse_xml })
		$ipAddress =  $deploymentResult.Deployment.RoleInstanceList.RoleInstance.IpAddress
		$winRmPort = ($roleResult.PersistentVMRole.ConfigurationSets.ConfigurationSet.InputEndpoints.InputEndpoint | ? { $_.Name -eq "WinRMHTTPs" }).LocalPort
		$this.WinRmUri = "https://$($ipAddress):$winRmPort"
		Write-Host $this.WirRmUri
	}
	$obj | Add-Member -Type ScriptMethod _waitForBoot -Value {
		while($true) {
			$result = $this.RestClient.Request(@{ Verb = "GET"; Resource = "services/hostedservices/$($this.ServiceName)/deployments/$($this.DeploymentName)"; OnResponse = $parse_xml })
			$powerState = ($result.Deployment.RoleInstanceList.RoleInstance | ? { $_.InstanceName -eq $vmName }).Powerstate
			$instanceStatus = ($result.Deployment.RoleInstanceList.RoleInstance | ? { $_.InstanceName -eq $vmName }).InstanceStatus
			Write-Host "Power State: $powerState"
			Write-Host "Instance Status: $instanceStatus"
			if($powerState -eq "Started" -And $instanceStatus -eq "ReadyRole") {
				break
			}
			Start-Sleep -Seconds 5
		}
	}
	$obj | Add-Member -Type ScriptMethod CreatePSSession { param($authentication)
		Write-Host "Authentication: $authentication"
		Write-Host "Connection Uri: $($this.WinRmUri)" 
		New-PSSession -ConnectionUri $this.WinRmUri -Credential $this.AdminUser.Credential -Authentication $authentication -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck)
	}
	$obj | Add-Member -Type ScriptMethod _waitForWinRm -Value {
		$numberOfTries = 0

		$session = $null
		$sessionCreated = $false

		while(!$sessionCreated) {
			try {
				Write-Host "Waiting for boot CredSSP attempt $numberOfTries"
				if($this.WinRmUri -eq $null) { $this._setWinRmUri() }
				$session = New-PsSession -ConnectionUri $this.WinRmUri -Credential $this.AdminUser.Credential -Authentication Negotiate -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck)
				$sessionCreated = $true
			} catch {
				if($numberOfTries -lt 40) { 
					Write-Host $_
					$numberOfTries++
					Start-Sleep -s 10
				} else {
					throw $_
				}
			} finally {
				if($null -ne $session) {
					Remove-PsSession $session
				}
			}

		}
	}
	$obj | Add-Member -Type ScriptMethod _downloadInstallers -Value {
		$sasProvider = new_shared_access_signature_provider $this.StorageAccount $this.StorageAccountKey

		$this.RemoteSession({ param($session)
			$session.Execute({ param($context)
				if(!(Test-Path $context.InstallersDirectory)) {
					New-Item $context.InstallersDirectory -Type Directory
				}
			})
			$this.Installers.GetEnumerator() | % {
				$url = $sasProvider.GetUrl("$($this.InstallersContainer)/$($_.Value)", "b", "r", [DateTime]::UtcNow.AddMinutes(1))
				$session.Execute({ param($context, $installerName, $installerSasUrl)
					$filePath = "$($context.InstallersDirectory)\$installerName"	
					Write-Host "trying to download installer: $installerName $installerSasUrl $filePath"
					$webRequest = [Net.WebRequest]::Create($installerSasUrl)
					$webRequest.Method = "GET"
					$response = $webRequest.GetResponse()
					$stream = $response.GetResponseStream()
					$file = [System.IO.File]::Create($filePath)
					$buffer = New-Object Byte[] 1024

					Do {
						$bytesRead = $stream.Read($buffer, 0, $buffer.Length)
						$file.Write($Buffer, 0, $BytesRead)
					} While ($bytesRead -gt 0)

					$stream.Close()

					$file.Flush()
					$file.Close()
					$file.Dispose()
				},
				@($_.Value, $url))
			}
		})
	}
	$obj
}
