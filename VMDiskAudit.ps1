Write-Host "Starting Disk Audit..."
$vmDiskTable = New-Object system.Data.DataTable "vmDisks"

function AddStringColumns() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$columns
    )
    foreach ($column in $columns.split(",")) {
        $columnToAdd = New-Object system.Data.DataColumn $column,([string])
        [Ref]$vmDiskTable.columns.add($columnToAdd)
    }
}

#From http://www.azurefieldnotes.com/2017/03/12/how-to-calculate-azure-vhds-used-space/
function Get-BlobBytes
{
    param (
        [Parameter(Mandatory=$true)]
        [Microsoft.WindowsAzure.Commands.Common.Storage.ResourceModel.AzureStorageBlob]$Blob)
  
    # Base + blob name
    $blobSizeInBytes = 124 + $Blob.Name.Length * 2
  
    # Get size of metadata
    $metadataEnumerator = $Blob.ICloudBlob.Metadata.GetEnumerator()
    while ($metadataEnumerator.MoveNext())
    {
        $blobSizeInBytes += 3 + $metadataEnumerator.Current.Key.Length + $metadataEnumerator.Current.Value.Length
    }
  
    if ($Blob.BlobType -eq [Microsoft.WindowsAzure.Storage.Blob.BlobType]::BlockBlob)
    {
        $blobSizeInBytes += 8
        $Blob.ICloudBlob.DownloadBlockList() | 
            ForEach-Object { $blobSizeInBytes += $_.Length + $_.Name.Length }
    }
    else
    {
        $Blob.ICloudBlob.GetPageRanges() | 
            ForEach-Object { $blobSizeInBytes += 12 + $_.EndOffset - $_.StartOffset }
    }
 
    return $blobSizeInBytes
}

AddStringColumns ("vmName,vmResourceGroup,vmLocation,vmTags,osType,dataOrOsDisk,diskSize,diskType,managedOrUnmanaged,storageAccount,consumedSize,diskCacheMode,diskCreateOption,diskName,diskResourceGroup,isOrphan")

Write-Host "Auditing Disks attached to VMs"
$virtualMachines = Get-AzureRmVM

foreach ($vm in $virtualMachines) {
    $row = $vmDiskTable.NewRow()

    $row.vmName = $vm.Name
    $row.vmResourceGroup = $vm.ResourceGroupName
    $row.vmTags = "{"
    foreach($tag in $vm.Tags) {
        [string]$key = $tag.Keys[0]
        [string]$value = $tag.Values[0]
        $row.vmTags += "`"$key`":`"$value`";"
    }
    $row.vmTags += "}"
    $row.vmLocation = $vm.Location

    #Start with OS Disk
    $row.osType = $vm.StorageProfile.osdisk.OsType
    $row.dataOrOsDisk = "os"
    $row.diskCacheMode = $vm.StorageProfile.osdisk.Caching
    $row.diskCreateOption = $vm.StorageProfile.osdisk.CreateOption
    $row.isOrphan = "false"

    if ($vm.StorageProfile.osdisk.ManagedDisk) {
        $row.managedOrUnmanaged = "managed"
        $osDisk = Get-AzureRmDisk | Where {$_.Id -eq $vm.StorageProfile.osdisk.ManagedDisk.Id}
        $row.diskType = $osDisk.AccountType
        $row.diskSize = $osDisk.DiskSizeGB
        $row.diskName = $osDisk.Name
        $row.diskResourceGroup = $osDisk.ResourceGroupName
    } else {
        $row.managedOrUnmanaged = "unmanaged"
        $row.diskSize = $vm.StorageProfile.osdisk.DiskSizeGB
        $uri = $vm.StorageProfile.osdisk.vhd.uri
        $storageAccount = Get-AzureRmStorageAccount | Where {$_.StorageAccountName -eq $uri.substring(8,$uri.IndexOf(".")-8)}
        $row.diskResourceGroup = $storageAccount.ResourceGroupName
        $row.storageAccount = $storageAccount.StorageAccountName
        $row.diskType = $storageAccount.Sku.Name
        $diskBlob = Get-AzureStorageBlob -Container "vhds" -Context $storageAccount.Context -Blob $uri.substring($uri.IndexOf("/vhds/")+6, $uri.Length - ($uri.IndexOf("/vhds/")+6))
        $row.consumedSize = (Get-BlobBytes($diskBlob)) / 1GB
    }

    $vmDiskTable.Rows.Add($row)

    $row = $vmDiskTable.NewRow()
    $row.isOrphan = "false"
    $row.vmName = $vm.Name
    $row.vmResourceGroup = $vm.ResourceGroupName
    $row.vmTags = "{"

    foreach($tag in $vm.Tags) {
        $row.vmTags += "`"[string]$tag.Keys[0]`":`"[string]$tag.values[0]`";"
    }

    $row.vmTags += "}"
    $row.vmLocation = $vm.Location

    foreach ($disk in $vm.DataDisks) {
        if ($disk.ManagedDisk) {
        $row.managedOrUnmanaged = "managed"
        $dataDisk = Get-AzureRmDisk | Where {$_.Id -eq $vm.StorageProfile.osdisk.ManagedDisk.Id}
        $row.diskType = $dataDisk.AccountType
        $row.diskSize = $dataDisk.DiskSizeGB
        $row.diskName = $dataDisk.Name
        $row.diskResourceGroup = $dataDisk.ResourceGroupName
        } else {
            $row.managedOrUnmanaged = "unmanaged"
            $row.diskSize = $disk.DiskSizeGB
            if ($uri) {
                $uri = $disk.vhd.uri
                $storageAccount = Get-AzureRmStorageAccount | Where {$_.StorageAccountName -eq $uri.substring(8,$uri.IndexOf(".")-8)}
                $row.diskResourceGroup = $storageAccount.ResourceGroupName
                $row.storageAccount = $storageAccount.StorageAccountName
                $row.diskType = $storageAccount.Sku.Name
                $arrUri = $uri.split("/")
                $diskBlob = Get-AzureStorageBlob -Container $arrUri[3] -Context $storageAccount.Context -Blob $uri.substring($uri.IndexOf("/vhds/")+6, $uri.Length - ($uri.IndexOf("/vhds/")+6))
                $row.consumedSize = (Get-BlobBytes($diskBlob)) / 1GB
            }
        }

    $vmDiskTable.Rows.Add($row)
    }
}

Write-Host "Checking for Orphaned managed Disks"

$orphanedManagedDisks = Get-AzureRmDisk | Where {$_.OwnerId -eq $null}

foreach ($disk in $orphanedManagedDisks) {
    $row = $vmDiskTable.NewRow()

    $row.diskType = $disk.AccountType
    $row.diskSize = $disk.DiskSizeGB
    $row.diskName = $disk.Name
    $row.osType = $disk.osType
    $row.diskResourceGroup = $disk.ResourceGroupName
    $row.managedOrUnmanaged = "managed"
    $row.isOrphan = "true"

    $vmDiskTable.Rows.Add($row)
}

Write-Host "Checking for Orphaned unmanaged Disks"

$storageAccounts = Get-AzureRmStorageAccount

foreach ($storageAccount in $storageAccounts) {
    

    $orphanedUnmanagedDisks = get-azurestoragecontainer -Context $storageAccount.Context | where {$_.Name -eq "vhds"} | get-azurestorageblob -Blob "*.vhd" | where {$_.SnapshotTime -eq $null -and $_.ICloudBlob.properties.LeaseState -ne "Leased"}
    
    foreach ($disk in $orphanedUnmanagedDisks) {
        $row = $vmDiskTable.NewRow()
        $row.diskName = $disk.Name
        $row.storageAccount = $disk.StorageAccountName
        $row.managedOrUnmanaged = "unmanaged"
        $row.diskSize = $disk.Length / 1GB
        $row.consumedSize = (Get-BlobBytes($disk)) / 1GB
        $row.isOrphan = "true"
        $vmDiskTable.Rows.Add($row)
    }
}
Write-Host "Exporting CSV.."

$vmDiskTable | export-csv -Path "diskaudit.csv"

Write-Host "Output written to diskaudit.csv"


