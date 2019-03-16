﻿param(
    [Parameter (Mandatory = $true)]
    [string]$SubscriptionName = "SEFONSEC Microsoft Azure Internal Consumption",
    #SEFONSEC Microsoft Azure Internal Consumption
)

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts
Import-Module Az.Sql
Import-Module Az.Resources

<#Enable for alert https://docs.microsoft.com/en-us/azure/automation/automation-alert-metric#>

<##########################################################################################################################################################
#Parameters
##########################################################################################################################################################>
[System.Collections.ArrayList]$AzureResourcesToIgnoreTypesFree = @(
    "microsoft.insights/alertrules",
    "Microsoft.Network/networkWatchers",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Sql/servers",
    "Microsoft.Automation/automationAccounts",
    "Microsoft.Automation/automationAccounts/runbooks",
    "microsoft.insights/actiongroups",
    "microsoft.insights/metricalerts",
    "Microsoft.Network/networkIntentPolicies",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/routeTables"
)

[string]$TagIgnoreName = "Ignore"
[string]$TagIgnoreValue = "true"
$ErrorActionPreference = "Stop"

<##########################################################################################################################################################
#Connect
##########################################################################################################################################################>
try{
    $Conn = Get-AutomationConnection -Name 'AzureRunAsConnection'
} catch {}

$context = Get-AzContext 

if ($context -eq $null)
{
    Connect-AzAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationId $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint -Subscription $Conn.SubscriptionId
}

##########################################################################################################################################################
#Get Resources Groups / Remove  Ignorables
##########################################################################################################################################################
Write-Output "---------------------------------------------------------------------------------------------------------------"
Write-Output "Will only evaluate the selected RESOURCE GROUPS"
Write-Output "---------------------------------------------------------------------------------------------------------------"

[System.Collections.ArrayList]$ResourceGroups = @()
[System.Collections.ArrayList]$ResourceGroupsToIgnore = @()

$ResourceGroups = @(Get-AzResourceGroup)

foreach ($AzureResourceGroup in $ResourceGroups)
{
    if ($AzureResourceGroup.Tags -ne $null)
    {
        if ($AzureResourceGroup.Tags.ContainsKey($TagIgnoreName))
        {
            if ($AzureResourceGroup.Tags.Item($TagIgnoreName) -eq $TagIgnoreValue)
            {
                Write-Output "Resource Group ($($AzureResourceGroup.ResourceGroupName)) with TAG - Ignore"
                $ResourceGroupsToIgnore.Add($AzureResourceGroup.ResourceGroupName) | Out-Null
            }
        }
    }
}

$ResourceGroups = @($ResourceGroups | Where-Object {$_.ResourceGroupName -notin $ResourceGroupsToIgnore})

Write-Output ($ResourceGroups | Select ResourceGroupName | Out-String)



##########################################################################################################################################################
#Get Resources / Remove Ignorables
##########################################################################################################################################################
Write-Output "---------------------------------------------------------------------------------------------------------------"
Write-Output "Will only evaluate the selected RESOURCES"
Write-Output "---------------------------------------------------------------------------------------------------------------"

[System.Collections.ArrayList]$AzureResources = @()
[System.Collections.ArrayList]$AzureResourcesToIgnore = @()

$AzureResources = @(Get-AzResource)

#Remove Resource Groups to Ignore
$AzureResources = @($AzureResources | Where-Object {$_.ResourceGroupName -notin $ResourceGroupsToIgnore})

#Remove Resources that are free / unexpensive
$AzureResources = $AzureResources | Where-Object {$_.ResourceType -notin $AzureResourcesToIgnoreTypesFree}

foreach ($AzureResource in $AzureResources)
{
    if (($AzureResource.Tags).Count -gt 0)
    {
        if ($AzureResource.Tags.ContainsKey($TagIgnoreName))
        {
            if ($AzureResource.Tags.Item($TagIgnoreName) -eq $TagIgnoreValue)
            {
                Write-Output "Resource ($($AzureResource.Name)) with TAG - Ignore"
                $AzureResourcesToIgnore.Add($AzureResource.ResourceId) | Out-Null
            }
        }
    }  
}
$AzureResources = @($AzureResources | Where-Object {$_.ResourceId -notin $AzureResourcesToIgnore})

Write-Output ($AzureResources | Select Type, ResourceGroupName, Name | Out-String)


##########################################################################################################################################################
#Get Databases / Remove Ignorables
##########################################################################################################################################################
Write-Output "---------------------------------------------------------------------------------------------------------------"
Write-Output "Get Databases / Remove Ignorables"
Write-Output "---------------------------------------------------------------------------------------------------------------"
[System.Collections.ArrayList]$AzureDatabases = @()
[System.Collections.ArrayList]$AzureDatabasesToIgnore = @()

$AzureDatabases = @($AzureResources | Where-Object {$_.Type -eq "Microsoft.Sql/servers/databases"})

foreach ($database in $AzureDatabases)
{
    $ServerName = ($database.Name -split '/')[0]
    $DatabaseName = ($database.Name -split '/')[1]

    if ($DatabaseName -eq "master")
    {        
        $AzureDatabasesToIgnore += $database
    }
    else
    {
        $databaseObject = Get-AzSqlDatabase -ResourceGroupName $database.ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName
        
        #Database basic are cheap - Ignore
        if ($databaseObject.SkuName -eq "Basic")
        {
            Write-Output "DB ($($database.Name)) is Basic - Ignore"
            $AzureDatabasesToIgnore += $database
        }
    }
}

foreach ($database in $AzureDatabasesToIgnore)
{
    $AzureResources.Remove($database)
}

Write-Output "Removed ($($AzureDatabasesToIgnore.Count) / $($AzureDatabases.Count)) databases"
Write-Output ""
##########################################################################################################################################################
#Get StorageAccounts / Remove Ignorables
##########################################################################################################################################################
Write-Output "---------------------------------------------------------------------------------------------------------------"
Write-Output "Get StorageAccounts / Remove Ignorables"
Write-Output "---------------------------------------------------------------------------------------------------------------"
[System.Collections.ArrayList]$AzureStorageAccounts = @()
[System.Collections.ArrayList]$AzureStorageAccountsToIgnore = @()

$AzureStorageAccounts = @($AzureResources | Where-Object {$_.Type -eq "Microsoft.Storage/storageAccounts"})

foreach ($StorageAccount in $AzureStorageAccounts)
{
    $StorageAccountObject = Get-AzStorageAccount -ResourceGroupName $StorageAccount.ResourceGroupName -Name $StorageAccount.Name
    
    #Storage Account standard are cheap - Ignore
    if ($StorageAccountObject.Sku.Tier -eq "Standard")
    {
        Write-Output "Storage Account ($($StorageAccountObject.StorageAccountName)) is Standard - Ignore"
        $AzureStorageAccountsToIgnore += $StorageAccount
    }
}

foreach ($StorageAccount in $AzureStorageAccountsToIgnore)
{
    $AzureResources.Remove($StorageAccount)
}

Write-Output "Removed ($($AzureStorageAccountsToIgnore.Count) / $($AzureStorageAccounts.Count)) storage accounts"
Write-Output ""

##########################################################################################################################################################
#ALERTS
##########################################################################################################################################################
[System.Collections.ArrayList]$ResourcesAlert = @()
if (($AzureResources | Select Type, ResourceGroupName, Name | Out-String).Length -gt 0)
{
    foreach ($AzureResource in @($AzureResources | Select Type, ResourceGroupName, Name))
    {
        $ResourcesAlert.Add($AzureResource) | Out-Null
    }
}

if($ResourcesAlert.Count -ge 1)
{
    Write-Output "---------------------------------------------------------------------------------------------------------------"
    Write-Output "Check this resources"
    Write-Output "---------------------------------------------------------------------------------------------------------------"
    Write-Output ($AzureResources | Select Type, ResourceGroupName, Name | Out-String)
    Write-Output "---------------------------------------------------------------------------------------------------------------"

    $NotificationText = "$($ResourcesAlert.Count) PAYING Resources"
    
    Write-Output "## Send Alert ##"
    Write-Output $NotificationText 
    Write-Error -Message ($NotificationText)

}
else
{
    Write-Output "## No issues ##"
}


