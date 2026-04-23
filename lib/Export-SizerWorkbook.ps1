#Requires -Version 7.0
#Requires -Modules ImportExcel

<#
.SYNOPSIS
    Writes the vSANBR analysis to a formatted .xlsx workbook.

.DESCRIPTION
    Sheets produced:
        Summary       Headline logical TiB + VM counts + flags
        BucketRollup  Totals per datastore bucket
        Datastores    Per-datastore detail with policy applied and VM rollup
        Vms           Per-VM breakdown (datastore, policy, InUse, logical)
        Crosscheck    Headline vs guest-OS consumed (vPartition), delta + %
        Straddlers    Advisory: VMs with disks spanning multiple datastores
        Assumptions   vSAN policy + dedup ratios applied
        Flags         Warnings, defaults used, powered-off notes, reclaim gaps
#>

function Export-SizerWorkbook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Analysis,
        [Parameter(Mandatory)] [pscustomobject] $Config,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter()] [string] $SourceLabel = ''
    )

    $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutputPath))
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

    $s = $Analysis.Summary
    $summaryRows = @(
        [pscustomobject]@{ Metric = 'Logical TiB (migration target)'; Value = $s.LogicalTiB_Total }
        [pscustomobject]@{ Metric = 'Primary source';                 Value = "vInfo.'In Use MiB' (summary.storage.committed per VM)" }
        [pscustomobject]@{ Metric = 'VMs analysed';                   Value = $s.VmCount }
        [pscustomobject]@{ Metric = 'VMs included in total';          Value = $s.VmIncluded }
        [pscustomobject]@{ Metric = 'VMs excluded (local/etc.)';      Value = $s.VmExcluded }
        [pscustomobject]@{ Metric = 'VMs powered off';                Value = $s.VmPoweredOff }
        [pscustomobject]@{ Metric = 'VMs with unmatched datastore';   Value = $s.VmOrphan }
        [pscustomobject]@{ Metric = 'Datastores analysed';            Value = $s.DatastoreCount }
        [pscustomobject]@{ Metric = 'VMs straddling datastores';      Value = $s.StraddlingVmCount }
        [pscustomobject]@{ Metric = 'Default dedup ratio used';       Value = $s.DefaultDedupRatioUsed }
        [pscustomobject]@{ Metric = 'Source';                         Value = $SourceLabel }
        [pscustomobject]@{ Metric = 'Generated';                      Value = (Get-Date).ToString('s') }
    )

    Write-Verbose "Writing Summary sheet"
    $summaryRows | Export-Excel -Path $OutputPath -WorksheetName 'Summary' -AutoSize -BoldTopRow -FreezeTopRow

    Write-Verbose "Writing BucketRollup sheet"
    @($Analysis.BucketRollup) | Export-Excel -Path $OutputPath -WorksheetName 'BucketRollup' -AutoSize -BoldTopRow -FreezeTopRow

    Write-Verbose "Writing Datastores sheet"
    @($Analysis.Datastores) | Export-Excel -Path $OutputPath -WorksheetName 'Datastores' -AutoSize -BoldTopRow -FreezeTopRow

    Write-Verbose "Writing Vms sheet"
    @($Analysis.Vms) | Export-Excel -Path $OutputPath -WorksheetName 'Vms' -AutoSize -BoldTopRow -FreezeTopRow

    $cc = $Analysis.Crosscheck
    $ccRows = @(
        [pscustomobject]@{ Metric = 'Headline TiB (vInfo, vSAN-reversed)';  Value = $cc.HeadlineTiB;      Note = 'Migration target. Sum of per-VM In Use MiB with vSAN FTT/RAID overhead removed.' }
        [pscustomobject]@{ Metric = 'Guest-OS consumed TiB (vPartition)';    Value = $cc.GuestConsumedTiB; Note = 'Sum of partition "Consumed MiB" across all guests. Independent view.' }
        [pscustomobject]@{ Metric = 'Guest-OS capacity TiB (vPartition)';    Value = $cc.GuestCapacityTiB; Note = 'Sum of partition sizes as seen inside guests.' }
        [pscustomobject]@{ Metric = 'Delta TiB (headline - guest)';           Value = $cc.DeltaTiB;         Note = 'Positive = headline exceeds guest view. Typical sources: thin-provisioning reclaim lag, orphan VMDKs, swap, VM metadata.' }
        [pscustomobject]@{ Metric = 'Delta %';                                Value = $cc.DeltaPct;         Note = 'Gap relative to headline. >30% surfaces a reclaim flag.' }
    )
    $ccRows | Export-Excel -Path $OutputPath -WorksheetName 'Crosscheck' -AutoSize -BoldTopRow -FreezeTopRow

    if (@($Analysis.Straddlers).Count -gt 0) {
        @($Analysis.Straddlers) | Export-Excel -Path $OutputPath -WorksheetName 'Straddlers' -AutoSize -BoldTopRow -FreezeTopRow
    } else {
        @([pscustomobject]@{ Info = 'No VMs with disks on more than one datastore, or vDisk tab was not present.' }) |
            Export-Excel -Path $OutputPath -WorksheetName 'Straddlers' -AutoSize -BoldTopRow -FreezeTopRow
    }

    $assumptionRows = New-Object System.Collections.Generic.List[object]
    $assumptionRows.Add([pscustomobject]@{
        Scope = 'DEFAULT'
        Ftt   = $Config.vsan.defaultPolicy.ftt
        Raid  = $Config.vsan.defaultPolicy.raid
        DedupCompressionRatio = $Config.vsan.defaultPolicy.dedupCompressionRatio
        RatioSource = $Config.vsan.defaultPolicy.dedupCompressionRatioSource
        Notes = 'Applied to every vSAN datastore unless overridden below.'
    }) | Out-Null
    foreach ($ov in @($Config.vsan.overrides)) {
        $scope = if ($ov.PSObject.Properties.Name -contains 'matchDatastoreName') {
            "Datastore=$($ov.matchDatastoreName)"
        } elseif ($ov.PSObject.Properties.Name -contains 'matchClusterName') {
            "Cluster=$($ov.matchClusterName)"
        } else { 'UNSCOPED' }
        $assumptionRows.Add([pscustomobject]@{
            Scope = $scope
            Ftt   = $ov.ftt
            Raid  = $ov.raid
            DedupCompressionRatio = $ov.dedupCompressionRatio
            RatioSource = $ov.dedupCompressionRatioSource
            Notes = if ($ov.PSObject.Properties.Name -contains '$comment') { [string]$ov.'$comment' } else { '' }
        }) | Out-Null
    }
    $assumptionRows.ToArray() | Export-Excel -Path $OutputPath -WorksheetName 'Assumptions' -AutoSize -BoldTopRow -FreezeTopRow

    $flagRows = @()
    foreach ($f in @($Analysis.Flags)) {
        $sev = if ($f -match '^WARN:') { 'WARN' }
               elseif ($f -match '^(DEFAULT_|POWERED_OFF_|ORPHAN_|STRADDLING_)') { 'INFO' }
               elseif ($f -match '^GUEST_RECLAIM_') { 'WARN' }
               else { 'INFO' }
        $flagRows += [pscustomobject]@{ Severity = $sev; Message = $f }
    }
    if ($flagRows.Count -eq 0) {
        $flagRows = @([pscustomobject]@{ Severity = 'INFO'; Message = 'No flags raised.' })
    }
    $flagRows | Export-Excel -Path $OutputPath -WorksheetName 'Flags' -AutoSize -BoldTopRow -FreezeTopRow

    return $OutputPath
}
