<#
.SYNOPSIS
    VM billing/reporting CSV using Veeam ONE REST API v2.3.

.DESCRIPTION
    Data sources and endpoints:
      - VM Name, Used Size, Provisioned Size, Last Backup, Job Name:
            GET /api/v2.3/protectedData/virtualMachines
      - Restore point count, total backup size, repository name:
            GET /api/v2.3/protectedData/virtualMachines/backups
      - Repository immutability:
            GET /api/v2.3/vbr/repositories/{repositoryId}
      - VM disk details (virtualDisks, totalDiskCapacityBytes) + oldest restore point (lastProtectedDate):
            GET /api/v2.3/vsphere/vms  (bulk, matched by moRef = vmIdInHypervisor)

    Output columns:
      - VM Name
      - Platform
      - Backup Server
      - Job Name
      - Job Type
      - VM Provisioned Size (GB)
      - VM Used Size (GB)
      - Latest Backup (Date)
      - Oldest Restore Point (Date)
      - Restore Points (In Total)
      - Total Backup Size (GB)
      - Backup Repository
      - Immutable

.PARAMETER VeeamOneServer
    Veeam ONE server hostname or IP.

.PARAMETER VeeamOnePort
    Port. Default: 1239.

.PARAMETER Credential
    PSCredential. Prompted if omitted.

.PARAMETER OutputPath
    Output CSV. Default: .\VeeamONEBillingReport_<datetime>.csv

.PARAMETER SkipCertificateCheck
    Skip TLS validation.

.EXAMPLE
    $cred = Get-Credential
    .\Get-VeeamONEBillingReport.ps1 -VeeamOneServer vone-server.domain.com -Credential $cred -SkipCertificateCheck

.NOTES
    Requires PowerShell 7+. Tested against Veeam ONE 13, REST API v2.3.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VeeamOneServer,
    [int]$VeeamOnePort = 1239,
    [PSCredential]$Credential,
    [string]$OutputPath = ".\VeeamONE-Report_Primary-Backups_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ─────────────────────────────────────────────────────────────

function ConvertTo-GB { param([long]$Bytes) [math]::Round($Bytes / 1GB, 2) }

function Invoke-OneApi {
    param([string]$Uri, [string]$Token)
    $raw = Invoke-RestMethod -Uri $Uri -Method GET `
        -Headers @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/json' } `
        -SkipCertificateCheck:$SkipCertificateCheck.IsPresent -SkipHttpErrorCheck
    if ($raw -is [string] -and $raw.Length -gt 0) {
        try { $raw = $raw | ConvertFrom-Json -Depth 20 } catch {}
    }
    return $raw
}

function Get-AllPages {
    param([string]$BaseUri, [string]$Token, [int]$PageSize = 500)
    $script:PagedItems = [System.Collections.Generic.List[PSObject]]::new()
    $offset = 0; $total = $null
    do {
        $sep  = if ($BaseUri -match '\?') { '&' } else { '?' }
        $page = Invoke-OneApi "${BaseUri}${sep}offset=${offset}&limit=${PageSize}" $Token
        if ($null -eq $page) { break }
        if ($page -is [string]) { try { $page = $page | ConvertFrom-Json -Depth 20 } catch { break } }

        $items = $null
        if ($page.PSObject.Properties['items']) {
            $items = @($page.items)
            if ($null -eq $total -and $page.PSObject.Properties['totalCount']) {
                $total = [int]$page.totalCount
            }
        } elseif ($page.PSObject.Properties['data']) {
            $items = @($page.data)
            if ($null -eq $total -and $page.PSObject.Properties['pagination'] -and
                $page.pagination.PSObject.Properties['total']) {
                $total = [int]$page.pagination.total
            }
        } else {
            Write-Warning "Unexpected response shape from ${BaseUri}: $($page.PSObject.Properties.Name -join ', ')"
            break
        }
        if ($null -eq $items -or $items.Count -eq 0) { break }
        foreach ($i in $items) { $script:PagedItems.Add($i) }
        $offset += $PageSize
        if ($null -ne $total -and $script:PagedItems.Count -ge $total) { break }
    } while ($items.Count -eq $PageSize)
}

#endregion

#region ── Authentication ──────────────────────────────────────────────────────

if (-not $Credential) { $Credential = Get-Credential -Message 'Veeam ONE credentials' }

Write-Host '[1/4] Authenticating with Veeam ONE...' -ForegroundColor Cyan

$tokenResp = Invoke-RestMethod `
    -Uri "https://${VeeamOneServer}:${VeeamOnePort}/api/token" `
    -Method POST `
    -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } `
    -Body @{ grant_type='password'; username=$Credential.UserName; password=$Credential.GetNetworkCredential().Password } `
    -SkipCertificateCheck:$SkipCertificateCheck.IsPresent

$token   = $tokenResp.access_token
$oneBase = "https://${VeeamOneServer}:${VeeamOnePort}/api/v2.3"
Write-Host '  ✓ Token acquired.' -ForegroundColor Green

#endregion

#region ── Step 1: Protected VMs ─────────────────────────────────────────────
# Fields used: name, vmUidInVbr, vmIdInHypervisor, backupServerName, platform,
#              usedSourceSizeBytes, provisionedSourceSizeBytes, lastProtectedDate, jobName

Write-Host '[2/4] Fetching protected VMs and backup records...' -ForegroundColor Cyan

Get-AllPages "$oneBase/protectedData/virtualMachines" $token
$protectedVms = @($script:PagedItems)
Write-Host "  ✓ $($protectedVms.Count) protected VMs." -ForegroundColor Green

#endregion

#region ── Step 2: Backup records + per-repo immutability ─────────────────────
# Fields used: vmUidInVbr, restorePoints, totalRestorePointSizeBytes,
#              repository.repositoryId, repository.name

Get-AllPages "$oneBase/protectedData/virtualMachines/backups" $token
$allBackups = @($script:PagedItems | Where-Object { $_.PSObject.Properties['type'] -and $_.type -eq 'VMBackup' })
Write-Host "  ✓ $($allBackups.Count) backup records (VMBackup only)." -ForegroundColor Green

# Build vmUidInVbr -> backup record and summed backup size across all records
$backupByVmUid    = @{}
$backupSizeByVmUid = @{}   # vmUidInVbr -> sum of totalRestorePointSizeBytes (long)
foreach ($b in $allBackups) {
    $vmUid = if ($b.PSObject.Properties['vmUidInVbr'] -and $b.vmUidInVbr) { $b.vmUidInVbr } else { $null }
    if (-not $vmUid) { continue }
    if (-not $backupByVmUid.ContainsKey($vmUid)) {
        $backupByVmUid[$vmUid] = $b
    }
    if ($b.PSObject.Properties['totalRestorePointSizeBytes'] -and $b.totalRestorePointSizeBytes -gt 0) {
        $backupSizeByVmUid[$vmUid] = ($backupSizeByVmUid[$vmUid] ?? 0L) + [long]$b.totalRestorePointSizeBytes
    }
}

# Collect unique repos from backup records, split by type
$repoIdToType = @{}
foreach ($b in $allBackups) {
    if (-not ($b.PSObject.Properties['repository'] -and $b.repository)) { continue }
    $repo = $b.repository
    if (-not ($repo.PSObject.Properties['repositoryId'] -and $repo.repositoryId)) { continue }
    $rid   = [string]$repo.repositoryId
    $rtype = if ($repo.PSObject.Properties['type'] -and $repo.type) { $repo.type } else { '' }
    if (-not $repoIdToType.ContainsKey($rid)) { $repoIdToType[$rid] = $rtype }
}

$repoImmutableMap = @{}   # repositoryId (string) -> bool

# Standard repos: fetch isImmutable directly
foreach ($rid in $repoIdToType.Keys) {
    if ($repoIdToType[$rid] -eq 'ScaleOut') { continue }
    try {
        $r = Invoke-OneApi "$oneBase/vbr/repositories/$rid" $token
        if ($null -ne $r -and $r -isnot [string] -and $r.PSObject.Properties['isImmutable']) {
            $repoImmutableMap[$rid] = [bool]$r.isImmutable
        }
    } catch { Write-Verbose "Repo $rid fetch failed: $_" }
}

# ScaleOut repos: check performance tiers + capacity tiers
# Both bulk endpoints return items with scaleoutRepositoryId and isImmutable.
# A SOBR is immutable if ANY extent in either tier has isImmutable = true.
$sobrIds = @($repoIdToType.Keys | Where-Object { $repoIdToType[$_] -eq 'ScaleOut' })
if ($sobrIds.Count -gt 0) {

    # Build scaleoutRepositoryId (string) -> isImmutable
    $sobrImmutableMap = @{}

    Get-AllPages "$oneBase/vbr/scaleoutRepositories/performanceTiers" $token
    foreach ($e in $script:PagedItems) {
        $sid = if ($e.PSObject.Properties['scaleoutRepositoryId'] -and $e.scaleoutRepositoryId) { [string]$e.scaleoutRepositoryId } else { $null }
        if (-not $sid) { continue }
        if (-not $sobrImmutableMap.ContainsKey($sid)) { $sobrImmutableMap[$sid] = $false }
        if ($e.PSObject.Properties['isImmutable'] -and [bool]$e.isImmutable) { $sobrImmutableMap[$sid] = $true }
    }
    Write-Host "  ✓ Performance tiers fetched ($($sobrImmutableMap.Count) SOBRs)." -ForegroundColor Green

    Get-AllPages "$oneBase/vbr/scaleoutRepositories/capacityTiers" $token
    foreach ($e in $script:PagedItems) {
        $sid = if ($e.PSObject.Properties['scaleoutRepositoryId'] -and $e.scaleoutRepositoryId) { [string]$e.scaleoutRepositoryId } else { $null }
        if (-not $sid) { continue }
        if (-not $sobrImmutableMap.ContainsKey($sid)) { $sobrImmutableMap[$sid] = $false }
        if ($e.PSObject.Properties['isImmutable'] -and [bool]$e.isImmutable) { $sobrImmutableMap[$sid] = $true }
    }
    Write-Host "  ✓ Capacity tiers fetched." -ForegroundColor Green

    # Link: backup record repository.repositoryId (ScaleOut) -> scaleoutRepositoryId
    # Match by name: backup record repository.name <-> SOBR name
    Get-AllPages "$oneBase/vbr/scaleoutRepositories" $token
    $sobrByName = @{}   # name (lowercase) -> scaleoutRepositoryId
    foreach ($s in $script:PagedItems) {
        $sid  = if ($s.PSObject.Properties['scaleoutRepositoryId'] -and $s.scaleoutRepositoryId) { [string]$s.scaleoutRepositoryId } else { $null }
        $snam = if ($s.PSObject.Properties['name'] -and $s.name) { $s.name.ToLower() } else { $null }
        if ($sid -and $snam) { $sobrByName[$snam] = $sid }
    }

    # Build name lookup from backup records for ScaleOut repos
    $scaleOutRepoNames = @{}  # repositoryId -> name (lowercase)
    foreach ($b in $allBackups) {
        if (-not ($b.PSObject.Properties['repository'] -and $b.repository)) { continue }
        $repo  = $b.repository
        $rid   = if ($repo.PSObject.Properties['repositoryId'] -and $repo.repositoryId) { [string]$repo.repositoryId } else { $null }
        $rtype = if ($repo.PSObject.Properties['type'] -and $repo.type) { $repo.type } else { '' }
        $rnam  = if ($repo.PSObject.Properties['name'] -and $repo.name) { $repo.name.ToLower() } else { $null }
        if ($rid -and $rtype -eq 'ScaleOut' -and $rnam -and -not $scaleOutRepoNames.ContainsKey($rid)) {
            $scaleOutRepoNames[$rid] = $rnam
        }
    }

    foreach ($rid in $scaleOutRepoNames.Keys) {
        $rnam = $scaleOutRepoNames[$rid]
        if ($sobrByName.ContainsKey($rnam)) {
            $sobrId = $sobrByName[$rnam]
            if ($sobrImmutableMap.ContainsKey($sobrId)) {
                $repoImmutableMap[$rid] = $sobrImmutableMap[$sobrId]
            }
        }
    }
}

$resolvedSobr = ($sobrIds | Where-Object { $repoImmutableMap.ContainsKey($_) }).Count
Write-Host "  ✓ $($repoImmutableMap.Count) / $($repoIdToType.Count) repositories with immutability resolved ($resolvedSobr ScaleOut)." -ForegroundColor Green


#endregion

#region ── Step 3: vSphere VM details ────────────────────────────────────────
# Fields used: moRef (matched to vmIdInHypervisor), virtualDisks, totalDiskCapacityBytes,
#              datastoreUsage[].commitedBytes, lastProtectedDate (oldest restore point)

Write-Host '[3/4] Fetching vSphere VM details...' -ForegroundColor Cyan

Get-AllPages "$oneBase/vsphere/vms" $token
$vsphereVms = @($script:PagedItems)
Write-Host "  ✓ $($vsphereVms.Count) vSphere VMs." -ForegroundColor Green

# Build lookups: moRef -> VM (primary), name -> VM (fallback)
$vsByMoRef = @{}
$vsByName  = @{}
foreach ($vm in $vsphereVms) {
    if ($vm.PSObject.Properties['moRef'] -and $vm.moRef) { $vsByMoRef[$vm.moRef] = $vm }
    if ($vm.PSObject.Properties['name']  -and $vm.name)  { $vsByName[$vm.name]   = $vm }
}

#endregion

#region ── Step 4: Build & export report ──────────────────────────────────────

Write-Host '[4/4] Building report...' -ForegroundColor Cyan

$report = foreach ($vm in $protectedVms) {
    $vmName = if ($vm.PSObject.Properties['name'] -and $vm.name) { $vm.name } else { 'Unknown' }
    $vmUid  = if ($vm.PSObject.Properties['vmUidInVbr'] -and $vm.vmUidInVbr) { $vm.vmUidInVbr } else { $null }
    # vmIdInHypervisor is the vSphere moRef (e.g. "vm-465129") for VSphere VMs
    $moRef  = if ($vm.PSObject.Properties['vmIdInHypervisor'] -and $vm.vmIdInHypervisor) { $vm.vmIdInHypervisor } else { $null }

    # Backup record for this VM
    $backupRec = if ($vmUid -and $backupByVmUid.ContainsKey($vmUid)) { $backupByVmUid[$vmUid] } else { $null }

    # vSphere VM — match by moRef first, then fall back to name
    $vsVm = if ($moRef -and $vsByMoRef.ContainsKey($moRef)) { $vsByMoRef[$moRef] }
             elseif ($vsByName.ContainsKey($vmName))          { $vsByName[$vmName] }
             else                                              { $null }

    # ── Sizes ─────────────────────────────────────────────────────────────────

    # Used size: usedSourceSizeBytes from protectedData
    $usedGB = if ($vm.PSObject.Properties['usedSourceSizeBytes'] -and $vm.usedSourceSizeBytes -gt 0) {
        ConvertTo-GB ([long]$vm.usedSourceSizeBytes)
    } else { 'N/A' }

    # Provisioned size: totalDiskCapacityBytes from vSphere (most accurate),
    #                   fall back to provisionedSourceSizeBytes from protectedData
    $provGB = if ($vsVm -and $vsVm.PSObject.Properties['totalDiskCapacityBytes'] -and $vsVm.totalDiskCapacityBytes -gt 0) {
        ConvertTo-GB ([long]$vsVm.totalDiskCapacityBytes)
    } elseif ($vm.PSObject.Properties['provisionedSourceSizeBytes'] -and $vm.provisionedSourceSizeBytes -gt 0) {
        ConvertTo-GB ([long]$vm.provisionedSourceSizeBytes)
    } else { 'N/A' }

    # ── Last backup (from protectedData VM) ───────────────────────────────────
    $lastBackup = if ($vm.PSObject.Properties['lastProtectedDate'] -and $vm.lastProtectedDate) {
        ([datetime]$vm.lastProtectedDate).ToString('yyyy-MM-dd HH:mm')
    } else { 'Never' }


    # ── Restore point count ───────────────────────────────────────────────────
    $rpCount = if ($backupRec -and $backupRec.PSObject.Properties['restorePoints'] -and $backupRec.restorePoints) {
        $backupRec.restorePoints
    } else { 'N/A' }

    # ── Total backup size ─────────────────────────────────────────────────────
    $totalBackupGB = if ($backupRec -and $backupRec.PSObject.Properties['totalRestorePointSizeBytes'] -and
                         $backupRec.totalRestorePointSizeBytes -gt 0) {
        ConvertTo-GB ([long]$backupRec.totalRestorePointSizeBytes)
    } else { 'N/A' }

    # ── Repository (name from backup record, isImmutable from per-repo fetch) ──
    $repoName    = 'N/A'
    $isImmutable = 'N/A'
    if ($backupRec -and $backupRec.PSObject.Properties['repository'] -and $backupRec.repository) {
        $repo     = $backupRec.repository
        $repoName = if ($repo.PSObject.Properties['name'] -and $repo.name) { $repo.name } else { 'N/A' }
        $rid      = if ($repo.PSObject.Properties['repositoryId'] -and $repo.repositoryId) { [string]$repo.repositoryId } else { $null }
        if ($rid -and $repoImmutableMap.ContainsKey($rid)) {
            $isImmutable = if ($repoImmutableMap[$rid]) { 'True' } else { 'False' }
        }
    }

    [PSCustomObject]@{
        'VM Name'                  = $vmName
        'Platform'                 = if ($vm.PSObject.Properties['platform'] -and $vm.platform) { $vm.platform } else { 'N/A' }
        'Backup Server'            = if ($vm.PSObject.Properties['backupServerName'] -and $vm.backupServerName) { $vm.backupServerName } else { 'N/A' }
        'Job Name'                 = if ($vm.PSObject.Properties['jobName'] -and $vm.jobName) { $vm.jobName } else { 'N/A' }
        'Job Type'                 = if ($backupRec -and $backupRec.PSObject.Properties['type'] -and $backupRec.type) { $backupRec.type } else { 'N/A' }
        'VM Provisioned Size (GB)'        = $provGB
        'VM Used Size (GB)'               = $usedGB
        'Backup Size (GB)'                = if ($vmUid -and $backupSizeByVmUid.ContainsKey($vmUid)) { ConvertTo-GB $backupSizeByVmUid[$vmUid] } else { 'N/A' }
        'Latest Backup (Date)'            = $lastBackup
        'Restore Points (In Total)'       = $rpCount
        'Total Backup Size (GB)'   = $totalBackupGB
        'Backup Repository'        = $repoName
        'Immutable'                = $isImmutable
    }
}

$sorted = $report | Sort-Object 'VM Name'
$sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "`n✅ Report exported: $OutputPath" -ForegroundColor Green
Write-Host "   Total VMs: $(@($sorted).Count)"
$sorted | Format-Table -Property * -AutoSize | Out-String -Width 9999 | Write-Host

#endregion