#Requires -Version 7.0
#Requires -Modules ImportExcel

<#
.SYNOPSIS
    vSANBR (vSAN Bloat Reduce) - strips vSAN FTT/RAID overhead from an RVTools
    export and produces the logical TiB required to migrate the environment.

.DESCRIPTION
    vSAN reports per-VM "In Use" capacity inclusive of replica/parity
    overhead. vSANBR reverses that FTT/RAID factor to recover the logical
    data the environment is holding:

        Logical = InUse / FttMultiplier

    Dedup/compression is NOT applied to the logical total at this time. The
    per-VM committed field is believed to exclude dedup savings (dedup is a
    cluster-scope property with no clean per-VM apportioning). The ratio is
    still accepted as a CLI argument and surfaced in the workbook but does
    not affect the headline pending customer ground-truth verification.

    Non-vSAN datastores (Nimble, VMFS, NFS, local) are counted at their reported
    In Use value. Results are written to a formatted xlsx.

.PARAMETER InputPath
    Folder containing RVTools_tab*.csv OR a single RVTools .xlsx export.

.PARAMETER OutputPath
    Path to the .xlsx file to create. Default: ./vSANBR-output.xlsx

.PARAMETER ConfigPath
    Optional path to a JSON config overriding vSAN policy, dedup ratio, and
    bucket rules. Defaults to config/default.json next to this script.

.PARAMETER DedupCompressionRatio
    Convenience flag: overrides the default vSAN dedup/compression ratio without
    requiring a custom config file. Stamped as CUSTOMER_REPORTED in the output.
    NOTE: currently advisory only - not applied to the logical total while
    the per-VM dedup semantics of vInfo 'In Use MiB' are being verified.

.PARAMETER Ftt
    Convenience flag: overrides the default vSAN FTT (0, 1, 2, or 3).

.PARAMETER Raid
    Convenience flag: overrides the default vSAN RAID (0, 1, 5, or 6).

.EXAMPLE
    ./vSANBR.ps1 -InputPath C:\RVTools\customer -OutputPath C:\tmp\sizing.xlsx

.EXAMPLE
    ./vSANBR.ps1 -InputPath .\samples\sanitized-rvtools -DedupCompressionRatio 1.78

.NOTES
    Requires PowerShell 7.x and the ImportExcel module.
#>

[CmdletBinding()]
param(
    [Parameter()] [string] $InputPath,
    [Parameter()] [string] $OutputPath = './vSANBR-output.xlsx',
    [Parameter()] [string] $ConfigPath,
    [Parameter()] [double] $DedupCompressionRatio,
    [Parameter()] [int]    $Ftt,
    [Parameter()] [int]    $Raid
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition }

. (Join-Path $scriptRoot 'lib/Read-RvInput.ps1')
. (Join-Path $scriptRoot 'lib/Group-DatastoreBucket.ps1')
. (Join-Path $scriptRoot 'lib/ConvertTo-VsanLogical.ps1')
. (Join-Path $scriptRoot 'lib/Invoke-vSANBRAnalysis.ps1')
. (Join-Path $scriptRoot 'lib/Export-SizerWorkbook.ps1')

if (-not $InputPath) {
    $InputPath = Read-Host "Path to RVTools folder or .xlsx"
}
if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "InputPath not found: $InputPath"
}

$endsWithSep = $OutputPath.EndsWith('\') -or $OutputPath.EndsWith('/')
$isExistingDir = (Test-Path -LiteralPath $OutputPath -PathType Container)
if ($endsWithSep -or $isExistingDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path -Path $OutputPath.TrimEnd('\','/') -ChildPath "vSANBR-$stamp.xlsx"
}
elseif (-not [System.IO.Path]::HasExtension($OutputPath)) {
    $OutputPath = "$OutputPath.xlsx"
}

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $scriptRoot 'config/default.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "ConfigPath not found: $ConfigPath"
}

$configJson = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

if ($PSBoundParameters.ContainsKey('DedupCompressionRatio')) {
    $configJson.vsan.defaultPolicy.dedupCompressionRatio = [double]$DedupCompressionRatio
    $configJson.vsan.defaultPolicy.dedupCompressionRatioSource = 'CUSTOMER_REPORTED'
}
if ($PSBoundParameters.ContainsKey('Ftt'))  { $configJson.vsan.defaultPolicy.ftt  = [int]$Ftt }
if ($PSBoundParameters.ContainsKey('Raid')) { $configJson.vsan.defaultPolicy.raid = [int]$Raid }

Write-Host "vSANBR - vSAN Bloat Reduce" -ForegroundColor Cyan
Write-Host "  Input : $InputPath"
Write-Host "  Output: $OutputPath"
Write-Host "  Config: $ConfigPath"
Write-Host ("  vSAN default policy : FTT={0} RAID={1} (Dedup={2}x advisory-only, {3})" -f `
    $configJson.vsan.defaultPolicy.ftt, $configJson.vsan.defaultPolicy.raid, `
    $configJson.vsan.defaultPolicy.dedupCompressionRatio, $configJson.vsan.defaultPolicy.dedupCompressionRatioSource)
Write-Host ''

Write-Host 'Reading input...' -ForegroundColor DarkGray
$data = Read-RvInput -Path $InputPath
Write-Host ("  Datastore rows: {0}  VM rows: {1}  Disk rows: {2}  Partition rows: {3}" -f `
    @($data.Datastore).Count, @($data.Info).Count, @($data.Disk).Count, @($data.Partition).Count)

Write-Host 'Running analysis...' -ForegroundColor DarkGray
$analysis = Invoke-vSANBRAnalysis -Data $data -Config $configJson

Write-Host 'Writing workbook...' -ForegroundColor DarkGray
$out = Export-SizerWorkbook -Analysis $analysis -Config $configJson -OutputPath $OutputPath -SourceLabel $InputPath

Write-Host ''
Write-Host '=== Headline ===' -ForegroundColor Green
Write-Host ("Logical TiB (migration target): {0:N2}" -f $analysis.Summary.LogicalTiB_Total) -ForegroundColor Green
Write-Host ("  Source: vInfo 'In Use MiB' (per VM), vSAN FTT/RAID overhead removed; dedup NOT applied")
Write-Host ("  VMs: {0} analysed / {1} included / {2} powered off / {3} orphan" -f `
    $analysis.Summary.VmCount, $analysis.Summary.VmIncluded, `
    $analysis.Summary.VmPoweredOff, $analysis.Summary.VmOrphan)
Write-Host ''
Write-Host 'Bucket rollup:'
$analysis.BucketRollup | Format-Table -AutoSize Bucket, DatastoreCount, IncludedCount, ExcludedCount, VmCount, CapacityTiB, VmInUseTiB, LogicalTiB | Out-String | Write-Host

$cc = $analysis.Crosscheck
Write-Host 'Crosscheck (vPartition):'
Write-Host ("  Headline:       {0,10:N2} TiB" -f $cc.HeadlineTiB)
Write-Host ("  Guest consumed: {0,10:N2} TiB" -f $cc.GuestConsumedTiB)
Write-Host ("  Delta:          {0,10:N2} TiB ({1:+0.0;-0.0}%)" -f $cc.DeltaTiB, $cc.DeltaPct)
Write-Host ''

if ($analysis.Flags.Count -gt 0) {
    Write-Host 'Flags:' -ForegroundColor Yellow
    foreach ($f in $analysis.Flags) {
        if ($f -match '^WARN:') { Write-Host "  $f" -ForegroundColor Red }
        elseif ($f -match '^DEFAULT_') { Write-Host "  $f" -ForegroundColor Yellow }
        else { Write-Host "  $f" }
    }
    Write-Host ''
}

Write-Host "Workbook written: $out" -ForegroundColor Cyan
