# AzureDiskAudit
Audits Azure Managed and Unmanaged Disks

This script links disks back to their owning Virtual Machines, scenarios where this is helpful is that if you have many virtual machines sharing storage accounts and need to be able to bill back the correct portion of the storage account to the virtual machine owner.

With billing in mind, for standard un-managed disks it calculates the consumed disk space as that is what is billed back.

It also identities potential orphan disks, orphan disks are identified as:
1. Managed Disks with no Owner allocated
2. Un-managed disks without a lease

You should validate that disks are indeed orphaned before deleting them!

Currently outputs to a simple CSV file.  
