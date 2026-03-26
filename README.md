# Created and tested with Veeam ONE 13

This script leverages the Veeam ONE 13 REST API to create a billing report with the data it pulled from VBR server(s).

To run, change the Run-Script.ps1 file to your Veeam ONE server and run it.

SCRIPT OUTPUT:

PowerShell credential request
Enter your credentials.
User: domain\username
Password for user domain\username: *********

[1/5] Authenticating with Veeam ONE...
  ✓ Token acquired.
[2/5] Fetching protected VMs...
  [DEBUG] /vbr/protectedData/virtualMachines -> Length
  [DEBUG] /protectedData/vbr/virtualMachines -> Length
  [DEBUG] Working endpoint: /protectedData/virtualMachines
  [DEBUG] Response props: items, totalCount
  ✓ 76 protected VMs.
  [DEBUG] protectedVM fields:
    vmId                                     = 
    vmUidInVbr                               = 3b0dd4a9-36e8-4381-a3e8-0a60e4bbba09
    vmIdInHypervisor                         = vm-465129
    backupServerId                           = 10740
    backupServerName                         = vbr1.domain.com
    name                                     = vm-name-1
    platform                                 = VSphere
    parentHostName                           = vcenter.domain.com
    ipAddresses                              = System.Object[]
    usedSourceSizeBytes                      = 487
    provisionedSourceSizeBytes               = 42949672960
    lastProtectedDate                        = 25/09/2025 11:12:56
    jobUid                                   = c529b5b0-cd70-4be2-a110-30758c08d060
    jobName                                  = VMware Templates
[3/5] Fetching backup details (totalRestorePointSizeBytes, restorePoints)...
  ✓ 150 backup records.
  [DEBUG] backup record fields:
    backupUid                                     = ae206a1e-057b-4729-bac5-1ec8ef5acc1d
    vmUidInVbr                                    = 1904e95c-091d-40f3-b1ed-e384b456bbb1
    jobUid                                        = abe43e48-c605-40a0-8477-462c9308167b
    jobName                                       = backup hyper-v
    type                                          = VMBackup
    totalRestorePointSizeBytes                    = 32494911488
    latestRestorePointSizeBytes                   = 3805151232
    restorePoints                                 = 15
    lastProtectedDate                             = 26/03/2026 10:01:00
    repository                                    = @{repositoryId=10735; repositoryUidInVbr=c28db527-671d-4071-9013-cd0c7a8caf27; type=ScaleOut; name=Backups}
    backupServerId                                = 10721
    backupServerName                              = vbr2.domain.com
    totalUniqueRestorePointsSizeBytes             = 16245784576
    uniqueRestorePoints                           = 7
  ✓ 20 unique job backup records.
  ✓ 12 repositories loaded.
  ✓ 3 backup servers loaded.
[4/5] Fetching vSphere VM disk details...
  ✓ 59 vSphere VMs.
[4b/5] Fetching oldest restore point per backup record...
  [DEBUG] ...
    ✓ Oldest restore points for 0 VMs.
[5/5] Building report...

✅ Report exported: .\VeeamONEBillingReport_20260326_145509.csv
   Total VMs: 76

VM Name                   Platform Backup Server      Job Name                VM Used Size (GB) VM Prov
                                                                                                isioned 
                                                                                                  Size  
                                                                                                   (GB) 
-------                   -------- -------------      --------                ----------------- -------
ubuntu-24.04              VSphere  vbr2.domain.com    Backup Job 1                         0,00   40,00 
TestVM                    HyperV   vbr2.domain.com    Hyper-V Job 1                        0,01  127,00 
ubuntu-24.04              VSphere  vbr2.domain.com    Backup Job 1                         0,00   40,00 
linux-vm1                 VSphere  vbr1.domain.com    Backup Job 2                        30,91  382,00 
vcenter                   VSphere  vbr1.domain.com    Backup Job 2                       252,24  701,47 

FULL REPORT CONTAINS THESE FIELDS AND VALUES:

VM Name
Platform
Backup Server
Job Name
VM Used Size (GB)
VM Provisioned Size (GB)
VM Disk Details
Last Backup
Oldest Restore Point
Restore Points
Total Backup Size (GB)
Backup Repository
Immutable