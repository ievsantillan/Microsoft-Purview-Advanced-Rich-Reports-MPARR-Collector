<#   
The MIT License (MIT)
Copyright (c) 2015 Microsoft Corporation
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>



<#
HISTORY
Script      : Get-PurviewRoles.ps1
Author      : S. Zamorano
Version     : 1.0.0
Description : The script exports Purview Roles assigned from Exchange Online API and pushes into a customer-specified Log Analytics table. Please note if you change the name of the table - you need to update Workbook sample that displays the report , appropriately. Do ensure the older table is deleted before creating the new table - it will create duplicates and Log analytics workspace doesn't support upserts or updates.

.NOTES 
	04-01-2024	S. Zamorano		- First release
#>


param (
    # Log Analytics table where the data is written to. Log Analytics will add an _CL to this name.
    [string]$TableName = "PurviewRoles",
	[Parameter()] 
        [switch]$ExportToFileOnly,
	[Parameter()] 
        [switch]$ManualConnection,
	[Parameter()] 
        [switch]$CreateTask

)

function CheckPowerShellVersion
{
    # Check PowerShell version
    Write-Host "`nChecking PowerShell version... " -NoNewline
    if ($Host.Version.Major -gt 5)
    {
        Write-Host "`t`t`t`tPassed!" -ForegroundColor Green
    }
    else
    {
        Write-Host "Failed" -ForegroundColor Red
        Write-Host "`tCurrent version is $($Host.Version). PowerShell version 7 or newer is required."
        exit(1)
    }
}

function CheckPrerequisites
{
    CheckPowerShellVersion
}

function ValidateConfigurationFile
{
	#Validate laconfig.json that manage the configuration for connections
	$MPARRConfiguration = "$PSScriptRoot\laconfig.json"
	
	if (-not (Test-Path -Path $MPARRConfiguration))
	{
		Write-Host "`nThe laconfig.json file is missing. Check if you are using the right path or execute MPARR_Setup.ps1 first."
		exit
	}else
	{
		#If the file is present we check if something is not correctly populated
		$CONFIGFILE = "$PSScriptRoot\laconfig.json"
		$json = Get-Content -Raw -Path $CONFIGFILE
		[PSCustomObject]$config = ConvertFrom-Json -InputObject $json
		
		$EncryptedKeys = $config.EncryptedKeys
		$AppClientID = $config.AppClientID
		$WLA_CustomerID = $config.LA_CustomerID
		$WLA_SharedKey = $config.LA_SharedKey
		$CertificateThumb = $config.CertificateThumb
		$OnmicrosoftTenant = $config.OnmicrosoftURL
		
		if($AppClientID -eq "") { Write-Host "Application Id is missing! Update the laconfig.json file and run again" -ForeGroundColor Red; exit }
		if($WLA_CustomerID -eq "")  { Write-Host "Logs Analytics workspace ID is missing! Update the laconfig.json file and run again" -ForeGroundColor Red; exit }
		if($WLA_SharedKey -eq "")  { Write-Host "Logs Analytics workspace key is missing! Update the laconfig.json file and run again" -ForeGroundColor Red; exit }
		if($CertificateThumb -eq "")  { Write-Host "Certificate thumbprint is missing! Update the laconfig.json file and run again" -ForeGroundColor Red; exit }
		if($OnmicrosoftTenant -eq "")  { Write-Host "Onmicrosoft domain is missing! Update the laconfig.json file and run again" -ForeGroundColor Red; exit }
		
		Write-Host "Configuration file validation..." -NoNewLine
		Write-Host "`t`t`tPassed!" -ForeGroundColor Green
		Start-Sleep -s 1
	}
}

function DecryptSharedKey 
{
    param(
        [string] $encryptedKey
    )

    try {
        $secureKey = $encryptedKey | ConvertTo-SecureString -ErrorAction Stop  
    }
    catch {
        Write-Error "Workspace key: $($_.Exception.Message)"
        exit(1)
    }
    $BSTR =  [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    $plainKey
}

function connect2service
{	
	ValidateConfigurationFile
	
	$CONFIGFILE = "$PSScriptRoot\laconfig.json"
	$json = Get-Content -Raw -Path $CONFIGFILE
	[PSCustomObject]$config = ConvertFrom-Json -InputObject $json
	
	$EncryptedKeys = $config.EncryptedKeys
	$AppClientID = $config.AppClientID
	$CertificateThumb = $config.CertificateThumb
	$OnmicrosoftTenant = $config.OnmicrosoftURL
	if ($EncryptedKeys -eq "True")
	{
		$CertificateThumb = DecryptSharedKey $CertificateThumb
	}
	
	<#
	.NOTES
	If you cannot add the "Compliance Administrator" role to the Microsoft Entra App, for security reasons, you can execute with "Compliance Administrator" role 
	this script using .\MPARR-ContentExplorer.ps1 -ManualConnection
	#>
	if($ManualConnection)
	{
		Write-Host "`nAuthentication is required, please check your browser" -ForegroundColor Green
		Connect-IPPSSession -UseRPSSession:$false
	}else
	{
		Connect-IPPSSession -CertificateThumbPrint $CertificateThumb -AppID $AppClientID -Organization $OnmicrosoftTenant
	}
}

function CreateScheduledTaskFolder
{
	param([string]$taskFolder)
	
	#Main interface to select folder
	Write-Host "`n`n----------------------------------------------------------------------------------------" -ForegroundColor Yellow
	Write-Host "`n Please be aware that this list of Task Scheduler folder don't show empty folders." -ForegroundColor Red
	Write-Host "`n----------------------------------------------------------------------------------------" -ForegroundColor Yellow
	
	# Generate a unique list of parent folders under task scheduler
	$TSFolder = Get-ScheduledTask
	$uniqueTaskFolder = $TSFolder.TaskPath | Select-Object -Unique
	$tempFolder = $uniqueTaskFolder -replace '^\\(\w+)\\.*?.*','$1'
	$listTaskFolders = $tempFolder | Select-Object -Unique
	foreach ($folder in $listTaskFolders){$SchedulerTaskFolders += @([pscustomobject]@{Name=$folder})}
	
	Write-Host "`nGetting Folders..." -ForegroundColor Green
    $i = 1
    $SchedulerTaskFolders = @($SchedulerTaskFolders | ForEach-Object {$_ | Add-Member -Name "No" -MemberType NoteProperty -Value ($i++) -PassThru})
    
	#List all existing folders under Task Scheduler
    $SchedulerTaskFolders | Select-Object No, Name | Out-Host
	
	# Default folder for MPARR tasks
    $MPARRTSFolder = "MPARR"
	$taskFolder = "\"+$MPARRTSFolder+"\"
	$choices  = '&Proceed', '&Change', '&Existing'
	Write-Host "Please consider if you want to use the default location you need select Existing and the option 1." -ForegroundColor Yellow
    $decision = $Host.UI.PromptForChoice("", "Default task Scheduler Folder is '$MPARRTSFolder'. Do you want to Proceed, Change the name or use Existing one?", $choices, 0)
    if ($decision -eq 1)
    {
        $ok = $false
        do 
        {
            $newName = Read-Host "Please enter the new name for the Task Scheduler folder"
        }
        until ($newName -ne "")
        $taskFolder = "\"+$newName+"\"
		Write-Host "The name selected for the folder under Task Scheduler is $newName." -ForegroundColor Green
		return $taskFolder
    }if ($decision -eq 0)
	{
		Write-Host "Using the default folder $MPARRTSFolder." -ForegroundColor Green
		return $taskFolder
	}else
	{
		$selection = 0
		ReadNumber -max ($i -1) -msg "Enter number corresponding to the current folder in the Task Scheduler" -option ([ref]$selection) 
		$value = $selection - 1
		$MPARRTSFolder = $SchedulerTaskFolders[$value].Name
		$taskFolder = "\"+$SchedulerTaskFolders[$value].Name+"\"
		Write-Host "Folder selected for this task $MPARRTSFolder " -ForegroundColor Green
		return $taskFolder
	}
	
}

function CreateMPARRPurviewRolesTask
{
	# MPARR-ContentExplorerData script
    $taskName = "MPARR-PurviewRoles"
	
	# Call function to set a folder for the task on Task Scheduler
	$taskFolder = CreateScheduledTaskFolder
	
	# Task execution
    $validDays = 30
    $choices  = '&Yes', '&No'
    $decision = $Host.UI.PromptForChoice("", "The task on task scheduler will be set for 30 days, do you want to change?", $choices, 1)
    if ($decision -eq 0)
    {
        ReadNumber -max 31 -msg "Enter number of days (Between 1 to 31). Remember check the retention period in your workspace in Logs Analtytics." -option ([ref]$validDays)
    }

    # calculate date
    $dt = Get-Date 
    $reminder = $dt.Day % $validDays
    $dt = $dt.AddDays(-$reminder)
    $startTime = [datetime]::new($dt.Year, $dt.Month, $dt.Day, $dt.Hour, $dt.Minute, 0)

    #create task
    $trigger = New-ScheduledTaskTrigger -Once -At $startTime -RepetitionInterval (New-TimeSpan -Days $validDays)
    $action = New-ScheduledTaskAction -Execute "`"$PSHOME\pwsh.exe`"" -Argument ".\MPARR-PurviewRoles.ps1" -WorkingDirectory $PSScriptRoot
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries `
         -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    if (Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue) 
    {
        Write-Host "`nScheduled task named '$taskName' already exists.`n" -ForegroundColor Yellow
    }
    else 
    {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -RunLevel Highest -TaskPath $taskFolder -ErrorAction Stop | Out-Null
        Write-Host "`nScheduled task named '$taskName' was created.`nFor security reasons you have to specify run as account manually.`n" -ForegroundColor Yellow
    }
}

function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) 
{
    # ---------------------------------------------------------------   
    #    Name           : Build-Signature
    #    Value          : Creates the authorization signature used in the REST API call to Log Analytics
    # ---------------------------------------------------------------

	#Original function to Logs Analytics
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}

function Post-LogAnalyticsData($body, $LogAnalyticsTableName) 
{
    # ---------------------------------------------------------------   
    #    Name           : Post-LogAnalyticsData
    #    Value          : Writes the data to Log Analytics using a REST API
    #    Input          : 1) PSObject with the data
    #                     2) Table name in Log Analytics
    #    Return         : None
    # ---------------------------------------------------------------
    
	#Read configuration file
	$CONFIGFILE = "$PSScriptRoot\laconfig.json"
	$json = Get-Content -Raw -Path $CONFIGFILE
	[PSCustomObject]$config = ConvertFrom-Json -InputObject $json
	
	$EncryptedKeys = $config.EncryptedKeys
	$WLA_CustomerID = $config.LA_CustomerID
	$WLA_SharedKey = $config.LA_SharedKey
	if ($EncryptedKeys -eq "True")
	{
		$WLA_SharedKey = DecryptSharedKey $WLA_SharedKey
	}

	# Your Log Analytics workspace ID
	$LogAnalyticsWorkspaceId = $WLA_CustomerID

	# Use either the primary or the secondary Connected Sources client authentication key   
	$LogAnalyticsPrimaryKey = $WLA_SharedKey 
	
    #Step 0: sanity checks
    if($body -isnot [array]) {return}
    if($body.Count -eq 0) {return}

    #Step 1: convert the PSObject to JSON
    $bodyJson = $body | ConvertTo-Json

    #Step 2: get the UTF8 bytestream for the JSON
    $bodyJsonUTF8 = ([System.Text.Encoding]::UTF8.GetBytes($bodyJson))

    #Step 3: build the signature        
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $bodyJsonUTF8.Length    
    $signature = Build-Signature -customerId $LogAnalyticsWorkspaceId -sharedKey $LogAnalyticsPrimaryKey -date $rfc1123date -contentLength $contentLength -method $method -contentType $contentType -resource $resource
    
    #Step 4: create the header
    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $LogAnalyticsTableName;
        "x-ms-date" = $rfc1123date;
    };

    #Step 5: REST API call
    $uri = 'https://' + $LogAnalyticsWorkspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
    $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType $contentType -Body $bodyJsonUTF8 -UseBasicParsing

    if ($Response.StatusCode -eq 200) {   
        $rows = $body.Count
        Write-Information -MessageData "   $rows rows written to Log Analytics workspace $uri" -InformationAction Continue
    }

}

function Export-PurviewRoles 
{
    # ---------------------------------------------------------------   
    #    Name           : Export-PurviewRoles
    #    Desc           : Extracts data from Get-RoleGroup and Get-RoleGroupMember into Log analytics workspace tables for reporting purposes
    #    Return         : None
    # ---------------------------------------------------------------
    
        connect2service

        # Run the commandlet to search through the Audit logs and get the AIP events in the specified timeframe
		$GetPurviewRole = Get-RoleGroup | %{$role = $_.name; Get-RoleGroupMember -Identity $_.Name} | select @{Name="Role"; Expression = {$role}}, DisplayName, Alias

        # Status update
        $recordsCount = $GetPurviewRole.Count
        Write-Information -MessageData "$recordsCount records returned from Purview Roles" -InformationAction Continue

        # If there is no data, skip
        if ($GetPurviewRole.Count -eq 0)
		{
			Write-Host "`nNo roles assigned was found on Purview Portal" -ForeGroundColor Yellow
			exit 
		}

        if($ExportToFileOnly)
		{
			$ExportPath = $PSScriptRoot+"\ExportedData"
			if(-Not (Test-Path $ExportPath ))
			{
				Write-Host "Export data directory is missing, creating a new folder called ExportedData"
				New-Item -ItemType Directory -Force -Path "$PSScriptRoot\ExportedData" | Out-Null
			}
			$date = Get-Date -Format "yyyyMMdd"
			$ExportFile = "MPARR - Purview roles assigned - "+$date+".csv"
			$path = $PSScriptRoot+"\ExportedData\"+$ExportFile
			$GetPurviewRole | Export-CSV $path
			Write-Host "`nExport file was named as :" -NoNewLine
			Write-Host $ExportFile -ForeGroundColor Green 
			Write-Host "`nFile was copied at :" -NoNewLine
			Write-Host $PSScriptRoot"\ExportedData" -ForeGroundColor Green 
			Write-Host "`n"
		}else
		{
			# Else format for Log Analytics
			$log_analytics_array = @()            
			foreach($i in $GetPurviewRole) {
				$log_analytics_array += $i
			}

			# Push data to Log Analytics
			Post-LogAnalyticsData -LogAnalyticsTableName $TableName -body $log_analytics_array
		}
    }
    
 
#Run the script.
CheckPrerequisites
Export-PurviewRoles