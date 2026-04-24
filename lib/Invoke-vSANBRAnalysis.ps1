#Requires -Version 7.0

<#
.SYNOPSIS
    Orchestrates the vSANBR analysis. Drives the headline from vInfo 'In Use MiB'
    (summary.storage.committed) and removes vSAN FTT/RAID overhead using the
    datastore each VM resides on.

.DESCRIPTION
    vInfo.'In Use MiB' captures VMDKs, snapshots, swap and VM metadata - the
    closest single-number answer to "what needs to move during a full
    evacuation". vDatastore is kept as the policy/type lookup. vPartition feeds
    a thin guest-OS-consumed crosscheck. vDisk, when present, powers an advisory
    straddle report for VMs whose disks span multiple datastores.

    Output shape:
        Summary       headline LogicalTiB_Total + counts + flags
        Datastores    per-datastore rollup (VM count, sums, policy applied)
        BucketRollup  per-bucket totals
        Vms           per-VM breakdown (VM, Datastore, Bucket, InUse, Logical)
        Crosscheck    headline vs guest-OS consumed, delta + %
        Straddlers    VMs spanning >=2 datastores (from vDisk; may be empty)
        Flags         strings surfacing notable conditions
#>

function ConvertTo-LongSafe {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return [long]0 }
    $s = "$Value" -replace '[,\s]', ''
    [long]$parsed = 0
    if ([long]::TryParse($s, [ref]$parsed)) { return $parsed }
    return [long]0
}

function Get-DatastoreTokenFromPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $m = [regex]::Match($Path, '^\s*\[([^\]]+)\]')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Invoke-vSANBRAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Data,
        [Parameter(Mandatory)] [pscustomobject] $Config
    )

    $dsRows = @($Data.Datastore)
    $vmRows = @($Data.Info)
    $diskRows = @($Data.Disk)
    $partRows = @($Data.Partition)
    $bucketRules = @($Config.buckets)
    $vsanCfg = $Config.vsan

    $flags = New-Object System.Collections.Generic.List[string]
    $defaultRatioUsed = $false

    # -- Build datastore lookup: Name (case-insensitive) -> record with bucket+policy
    $dsIndex = @{}
    $datastoreRecs = New-Object System.Collections.Generic.List[object]
    foreach ($ds in $dsRows) {
        $name = [string]$ds.'Name'
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $type = if ($ds.PSObject.Properties.Name -contains 'Type' -and $null -ne $ds.'Type') { [string]$ds.'Type' } else { '' }
        $cluster = if ($ds.PSObject.Properties.Name -contains 'Cluster name' -and $null -ne $ds.'Cluster name') { [string]$ds.'Cluster name' } else { '' }
        $hostCount = ConvertTo-LongSafe $ds.'# Hosts'
        $bucket = Get-DatastoreBucket -Name $name -Type $type -BucketRules $bucketRules

        $ftt = $null; $raid = $null; $ratio = 1.0; $ratioSource = 'N/A'; $mult = 1.0
        if ($type -ieq 'vsan') {
            $policy = Get-VsanPolicyForDatastore -DatastoreName $name -ClusterName $cluster -VsanConfig $vsanCfg
            $ftt = [int]$policy.ftt
            $raid = [int]$policy.raid
            $ratio = if ($policy.PSObject.Properties.Name -contains 'dedupCompressionRatio') { [double]$policy.dedupCompressionRatio } else { 1.0 }
            $ratioSource = if ($policy.PSObject.Properties.Name -contains 'dedupCompressionRatioSource') { [string]$policy.dedupCompressionRatioSource } else { 'UNSPECIFIED' }
            $mult = Get-VsanFttMultiplier -Ftt $ftt -Raid $raid
            if ($ratioSource -eq 'DEFAULT_ASSUMED_AVERAGE') { $defaultRatioUsed = $true }

            if ($hostCount -gt 0) {
                $minHosts = switch ("$ftt/$raid") { '1/5' { 4 } '2/6' { 6 } '2/1' { 4 } '3/1' { 5 } default { 3 } }
                if ($hostCount -lt $minHosts) {
                    $flags.Add("WARN: datastore '$name' has $hostCount hosts but policy FTT=$ftt RAID=$raid requires >= $minHosts hosts.") | Out-Null
                }
            }
        }

        $rec = [pscustomobject]@{
            Name              = $name
            Type              = $type
            Cluster           = $cluster
            HostCount         = [int]$hostCount
            Bucket            = $bucket.Name
            Excluded          = $bucket.Exclude
            ExcludeReason     = $bucket.ExcludeReason
            CapacityMiB       = ConvertTo-LongSafe $ds.'Capacity MiB'
            ReportedInUseMiB  = ConvertTo-LongSafe $ds.'In Use MiB'
            Ftt               = $ftt
            Raid              = $raid
            FttMultiplier     = $mult
            DedupCompressionRatio = $ratio
            RatioSource       = $ratioSource
            VmCount           = 0
            VmInUseMiB        = [long]0
            LogicalMiB        = [long]0
        }
        $datastoreRecs.Add($rec) | Out-Null
        $dsIndex[$name.ToLowerInvariant()] = $rec
    }

    # -- Iterate vInfo; attribute each VM's 'In Use MiB' to its primary datastore
    $vms = New-Object System.Collections.Generic.List[object]
    $orphanCount = 0; $orphanMiB = [long]0
    $poweredOff = 0
    foreach ($v in $vmRows) {
        $vmName = [string]$v.'VM'
        $powerstate = [string]$v.'Powerstate'
        $inUseMiB = ConvertTo-LongSafe $v.'In Use MiB'
        $provMiB = ConvertTo-LongSafe $v.'Provisioned MiB'
        $path = [string]$v.'Path'
        $dsToken = Get-DatastoreTokenFromPath -Path $path
        $rec = if ($dsToken) { $dsIndex[$dsToken.ToLowerInvariant()] } else { $null }

        $dsName = ''; $bucketName = 'Orphan (no datastore)'; $excluded = $false
        $ftt = $null; $raid = $null; $ratio = 1.0; $mult = 1.0
        $logicalMiB = [long]0

        if ($rec) {
            $dsName = $rec.Name
            $bucketName = $rec.Bucket
            $excluded = $rec.Excluded
            $ftt = $rec.Ftt; $raid = $rec.Raid; $ratio = $rec.DedupCompressionRatio; $mult = $rec.FttMultiplier
            if ($excluded) {
                $logicalMiB = 0
            } elseif ($rec.Type -ieq 'vsan') {
                $logicalMiB = ConvertTo-VsanLogicalMiB -InUseMiB $inUseMiB -Ftt $ftt -Raid $raid -DedupCompressionRatio $ratio
            } else {
                $logicalMiB = $inUseMiB
            }
            $rec.VmCount++
            $rec.VmInUseMiB += $inUseMiB
            $rec.LogicalMiB += $logicalMiB
        } else {
            $orphanCount++
            $orphanMiB += $inUseMiB
            $logicalMiB = $inUseMiB
        }

        if ($powerstate -ieq 'poweredOff') { $poweredOff++ }

        $vms.Add([pscustomobject]@{
            VM              = $vmName
            Powerstate      = $powerstate
            Datastore       = $dsName
            DatastoreToken  = $dsToken
            Bucket          = $bucketName
            Excluded        = $excluded
            Ftt             = $ftt
            Raid            = $raid
            DedupCompressionRatio = $ratio
            InUseMiB        = $inUseMiB
            ProvisionedMiB  = $provMiB
            LogicalMiB      = [long]$logicalMiB
            InUseTiB        = ConvertTo-TiB -MiB $inUseMiB
            LogicalTiB      = ConvertTo-TiB -MiB $logicalMiB
        }) | Out-Null
    }

    # -- Finalise datastore TiB columns + per-bucket rollup
    foreach ($rec in $datastoreRecs) {
        Add-Member -InputObject $rec -NotePropertyName CapacityTiB -NotePropertyValue (ConvertTo-TiB -MiB $rec.CapacityMiB) -Force
        Add-Member -InputObject $rec -NotePropertyName VmInUseTiB  -NotePropertyValue (ConvertTo-TiB -MiB $rec.VmInUseMiB) -Force
        Add-Member -InputObject $rec -NotePropertyName LogicalTiB  -NotePropertyValue (ConvertTo-TiB -MiB $rec.LogicalMiB) -Force
    }

    $buckets = $datastoreRecs | Group-Object -Property Bucket | ForEach-Object {
        $included = @($_.Group | Where-Object { -not $_.Excluded })
        $excluded = @($_.Group | Where-Object { $_.Excluded })
        $sumCap = [long]0; $sumInUse = [long]0; $sumLog = [long]0; $sumVms = 0
        foreach ($r in $_.Group) { $sumCap += $r.CapacityMiB; $sumInUse += $r.VmInUseMiB; $sumLog += $r.LogicalMiB; $sumVms += $r.VmCount }
        [pscustomobject]@{
            Bucket          = $_.Name
            DatastoreCount  = $_.Count
            IncludedCount   = $included.Count
            ExcludedCount   = $excluded.Count
            VmCount         = $sumVms
            CapacityTiB     = ConvertTo-TiB -MiB $sumCap
            VmInUseTiB      = ConvertTo-TiB -MiB $sumInUse
            LogicalTiB      = ConvertTo-TiB -MiB $sumLog
            ContributesToTotal = ($included.Count -gt 0)
        }
    } | Sort-Object Bucket

    $totalLogicalMiB = [long]0
    foreach ($vm in $vms) { if (-not $vm.Excluded) { $totalLogicalMiB += $vm.LogicalMiB } }

    # -- vPartition crosscheck: guest-OS consumed vs headline
    $guestConsumedMiB = [long]0; $guestCapacityMiB = [long]0
    foreach ($p in $partRows) {
        $guestConsumedMiB += ConvertTo-LongSafe $p.'Consumed MiB'
        $guestCapacityMiB += ConvertTo-LongSafe $p.'Capacity MiB'
    }
    $headlineTiB = ConvertTo-TiB -MiB $totalLogicalMiB
    $guestConsumedTiB = ConvertTo-TiB -MiB $guestConsumedMiB
    $deltaTiB = [math]::Round($headlineTiB - $guestConsumedTiB, 2)
    $deltaPct = if ($headlineTiB -gt 0) { [math]::Round(($deltaTiB / $headlineTiB) * 100.0, 1) } else { 0.0 }

    $crosscheck = [pscustomobject]@{
        HeadlineTiB       = $headlineTiB
        GuestConsumedTiB  = $guestConsumedTiB
        GuestCapacityTiB  = ConvertTo-TiB -MiB $guestCapacityMiB
        DeltaTiB          = $deltaTiB
        DeltaPct          = $deltaPct
    }

    # -- Straddle advisory (vDisk): VMs whose disks span >=2 datastores
    $straddlers = New-Object System.Collections.Generic.List[object]
    if ($diskRows.Count -gt 0) {
        $byVm = @{}
        foreach ($d in $diskRows) {
            $vn = [string]$d.'VM'
            if ([string]::IsNullOrWhiteSpace($vn)) { continue }
            $dt = Get-DatastoreTokenFromPath -Path ([string]$d.'Path')
            if (-not $dt) { continue }
            if (-not $byVm.ContainsKey($vn)) { $byVm[$vn] = New-Object System.Collections.Generic.List[string] }
            $byVm[$vn].Add($dt) | Out-Null
        }
        foreach ($kv in $byVm.GetEnumerator()) {
            $distinct = @($kv.Value | Select-Object -Unique)
            if ($distinct.Count -ge 2) {
                $clusters = @()
                foreach ($dsTok in $distinct) {
                    $rec = $dsIndex[$dsTok.ToLowerInvariant()]
                    if ($rec -and $rec.Cluster) { $clusters += $rec.Cluster }
                }
                $straddlers.Add([pscustomobject]@{
                    VM                   = $kv.Key
                    DatastoreCount       = $distinct.Count
                    Datastores           = ($distinct -join '; ')
                    Clusters             = (($clusters | Select-Object -Unique) -join '; ')
                    CrossesClusterBoundary = (@($clusters | Select-Object -Unique).Count -gt 1)
                }) | Out-Null
            }
        }
    }

    # -- Flags
    $flags.Add("DEDUP_NOT_APPLIED: vInfo 'In Use MiB' is believed to include FTT/RAID overhead but NOT dedup/compression at the per-VM level. The headline removes FTT only. If VsanQuerySpaceUsage on the source cluster shows a meaningful dedup ratio AND confirms per-VM committed is post-dedup, multiply the headline by that ratio manually.") | Out-Null
    if ($defaultRatioUsed) {
        $flags.Add("DEFAULT_DEDUP_RATIO: default 1.5x dedup/compression ratio is configured but not applied to the logical total (advisory only while dedup handling is under verification).") | Out-Null
    }
    if ($poweredOff -gt 0) {
        $flags.Add("POWERED_OFF_VMS: $poweredOff VMs are powered off - their 'In Use MiB' excludes swap (.vswp) space. Review whether migrating them is in scope.") | Out-Null
    }
    if ($orphanCount -gt 0) {
        $flags.Add("ORPHAN_VMS: $orphanCount VMs in vInfo had a Path whose datastore is not listed in vDatastore; they were counted at reported In Use with no vSAN reversal applied.") | Out-Null
    }
    if ([math]::Abs($deltaPct) -ge 30 -and $headlineTiB -gt 0) {
        $flags.Add(("GUEST_RECLAIM_GAP: headline {0:N1} TiB vs guest-OS consumed {1:N1} TiB ({2:+0.0;-0.0}%). Large gaps typically indicate thin-provisioning reclaim lag or orphan VMDKs. Worth investigating before finalising sizing." -f $headlineTiB, $guestConsumedTiB, $deltaPct)) | Out-Null
    }
    if ($straddlers.Count -gt 0) {
        $flags.Add("STRADDLING_VMS: $($straddlers.Count) VMs have disks on >=2 datastores. See the Straddlers sheet - advisory only, does not affect the headline when the goal is full evacuation.") | Out-Null
    }

    $summary = [pscustomobject]@{
        LogicalTiB_Total      = $headlineTiB
        LogicalMiB_Total      = [long]$totalLogicalMiB
        VmCount               = $vms.Count
        VmIncluded            = ($vms | Where-Object { -not $_.Excluded }).Count
        VmExcluded            = ($vms | Where-Object { $_.Excluded }).Count
        VmPoweredOff          = $poweredOff
        VmOrphan              = $orphanCount
        DatastoreCount        = $datastoreRecs.Count
        StraddlingVmCount     = $straddlers.Count
        DefaultDedupRatioUsed = $defaultRatioUsed
    }

    return [pscustomobject]@{
        Datastores   = $datastoreRecs.ToArray()
        BucketRollup = @($buckets)
        Vms          = $vms.ToArray()
        Crosscheck   = $crosscheck
        Straddlers   = $straddlers.ToArray()
        Flags        = @($flags)
        Summary      = $summary
    }
}
