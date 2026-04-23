#Requires -Version 7.0

<#
.SYNOPSIS
    Sanitizes an RVTools CSV export by masking identifying strings while
    preserving every numeric value and the structural relationships that the
    sizer relies on.

.DESCRIPTION
    Walks every RVTools_tab*.csv in the source folder, builds a deterministic
    token map for each identifier category, then re-emits the files with masked
    strings. The same original value always maps to the same sanitized token
    across every file so joins still work.

    Sanitized categories:
        VM name          vm0001, vm0002, ...
        Host name        esxi001.example.local
        Cluster name     cluster01
        Datacenter       datacenter01
        Datastore name   preserves a type prefix (vsan-, nimble-, vmfs-, nfs-, local-)
                         so bucket rules still classify correctly, e.g. vsan-ds-042
        IPs              10.200.x.y (deterministic within run)
        MAC              stripped
        UUIDs / Object IDs  replaced with uuid-0001 style tokens

    Free-text columns (annotation, description, contact, notes, tags) are
    replaced with empty strings. Numeric columns are never touched.

.PARAMETER InputPath
    Folder containing the real RVTools_tab*.csv files. Read-only.

.PARAMETER OutputPath
    Folder to write sanitized CSVs into. Created if missing.

.PARAMETER MapPath
    Optional path to write the JSON token map (debug aid; contains real->fake
    mappings so DO NOT share this file externally).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $InputPath,
    [Parameter(Mandatory)] [string] $OutputPath,
    [Parameter()] [string] $MapPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath -PathType Container)) {
    throw "InputPath not found or not a folder: $InputPath"
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$script:VmMap        = @{}
$script:HostMap      = @{}
$script:ClusterMap   = @{}
$script:DcMap        = @{}
$script:DatastoreMap = @{}
$script:IpMap        = @{}
$script:UuidMap      = @{}
$script:FolderMap    = @{}

function Get-Token {
    param([hashtable]$Map, [string]$Key, [string]$Prefix, [string]$Suffix = '')
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    if ($Map.ContainsKey($Key)) { return $Map[$Key] }
    $n = $Map.Count + 1
    $tok = ('{0}{1:D4}{2}' -f $Prefix, $n, $Suffix)
    $Map[$Key] = $tok
    return $tok
}

function Get-DatastoreToken {
    param([string]$Name, [string]$Type)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($script:DatastoreMap.ContainsKey($Name)) { return $script:DatastoreMap[$Name] }
    $prefix = switch -Regex ($Name) {
        '(?i)vsan'   { 'vsan-ds-';   break }
        '(?i)nimble' { 'nimble-ds-'; break }
        '(?i)datastore[0-9]+|z_local|^local[-_]' { 'local-ds-'; break }
        default {
            if ($Type -ieq 'NFS')  { 'nfs-ds-' }
            elseif ($Type -ieq 'VMFS') { 'vmfs-ds-' }
            elseif ($Type -ieq 'vsan') { 'vsan-ds-' }
            else { 'ds-' }
        }
    }
    $n = ($script:DatastoreMap.Values | Where-Object { $_ -like "$prefix*" } | Measure-Object).Count + 1
    $tok = ('{0}{1:D3}' -f $prefix, $n)
    $script:DatastoreMap[$Name] = $tok
    return $tok
}

function Get-IpToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $parts = $Value -split '[;,\s]+' | Where-Object { $_ }
    $out = foreach ($p in $parts) {
        if ($p -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') {
            if (-not $script:IpMap.ContainsKey($p)) {
                $n = $script:IpMap.Count + 1
                $script:IpMap[$p] = ('10.200.{0}.{1}' -f [math]::Floor($n / 254), (($n % 254) + 1))
            }
            $script:IpMap[$p]
        } elseif ($p -match ':') {
            if (-not $script:IpMap.ContainsKey($p)) {
                $n = $script:IpMap.Count + 1
                $script:IpMap[$p] = ('fd00::{0:x}' -f $n)
            }
            $script:IpMap[$p]
        } else { $p }
    }
    return ($out -join ', ')
}

function Get-UuidToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($script:UuidMap.ContainsKey($Value)) { return $script:UuidMap[$Value] }
    $n = $script:UuidMap.Count + 1
    $tok = ('uuid-{0:D5}' -f $n)
    $script:UuidMap[$Value] = $tok
    return $tok
}

function Get-FolderToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($script:FolderMap.ContainsKey($Value)) { return $script:FolderMap[$Value] }
    $depth = ($Value -split '/').Count
    $n = $script:FolderMap.Count + 1
    $tok = ('/folder{0:D3}' -f $n) + (('/sub' * [math]::Max(0, $depth - 2)))
    $script:FolderMap[$Value] = $tok
    return $tok
}

function Get-DatastorePathToken {
    # vInfo.Path and vDisk.Path use '[datastore-name] folder/file.ext'.
    # We must preserve the '[ds-token]' prefix so vSANBR can join on datastore,
    # while masking the folder/file portion.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $m = [regex]::Match($Value, '^\s*\[([^\]]+)\]\s*(.*)$')
    if (-not $m.Success) { return (Get-FolderToken -Value $Value) }
    $dsReal = $m.Groups[1].Value
    $tail = $m.Groups[2].Value
    $dsTok = Get-DatastoreToken -Name $dsReal -Type ''
    $ext = ''
    $mExt = [regex]::Match($tail, '\.[A-Za-z0-9]{2,6}$')
    if ($mExt.Success) { $ext = $mExt.Value }
    $tailTok = if ([string]::IsNullOrWhiteSpace($tail)) { '' } else { (Get-FolderToken -Value $tail).TrimStart('/') + $ext }
    if ($tailTok) { return ('[{0}] {1}' -f $dsTok, $tailTok) }
    return ('[{0}]' -f $dsTok)
}

# Columns we wipe entirely (customer free-text / PII)
$FreeTextColumns = @(
    'Annotation','annotation','description','contact','notes','Notes','dept','division',
    'app','campus','elcid','env','security','owner','Owner','Rubrik_LastBackup',
    'com.vmware.vdp2.is-protected','com.vmware.vdp2.protected-by',
    'Custom Attribute','CustomAttribute'
)

# Columns whose values are identifiers we rewrite
$VmColumns       = @('VM')
$HostColumnsHost = @('Host')         # in vHost tab the host IS the row key
$HostColumns     = @('Host','Hosts','Console','NTP Server(s)','Service Console','VMotion server','ESX Server')
$ClusterColumns  = @('Cluster','Cluster name')
$DcColumns       = @('Datacenter')
$DsColumnsName   = @('Name')         # vDatastore has the datastore name in 'Name'
$DsColumns       = @('Datastore','Datastore Name')
$IpColumns       = @('Primary IP Address','IP Address','IPv4 Address','IPv6 Address','IP','VMkernel gateway','DNS servers','NTP Server(s)')
$DnsColumns      = @('DNS Name')
$UuidColumns     = @('VM UUID','BIOS UUID','Instance UUID','VI SDK UUID','Object ID','VM ID','MoRef','Switch Object ID','Port Key','Device ID','Address','NAA','EUI','WWN','Serial','Service tag')
$FolderColumns   = @('Folder','Path','Resource pool')
$MacColumns      = @('Mac Address','MAC','Mac')
$UrlColumns      = @('URL','VI SDK Server')

function Invoke-RowSanitize {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Row, [string]$TabName)

    $props = @($Row.PSObject.Properties.Name)
    # Datastore Type is needed before we map the Name
    $rowType = if ($props -contains 'Type') { [string]$Row.'Type' } else { '' }

    foreach ($col in $props) {
        $val = [string]$Row.$col
        if ([string]::IsNullOrEmpty($val)) { continue }

        if ($FreeTextColumns -contains $col) { $Row.$col = ''; continue }

        if ($col -eq 'Name' -and $TabName -eq 'vDatastore') {
            $Row.$col = Get-DatastoreToken -Name $val -Type $rowType; continue
        }
        if ($VmColumns -contains $col)      { $Row.$col = Get-Token -Map $script:VmMap      -Key $val -Prefix 'vm';       continue }
        if ($DnsColumns -contains $col)     { $tok = Get-Token -Map $script:VmMap -Key $val -Prefix 'vm'; $Row.$col = if($tok){"$tok.example.local"}else{''}; continue }
        if ($col -eq 'Host' -and $TabName -eq 'vHost') {
            $Row.$col = Get-Token -Map $script:HostMap -Key $val -Prefix 'esxi' -Suffix '.example.local'; continue
        }
        if ($HostColumns -contains $col)    {
            $pieces = $val -split '[;,\s]+' | Where-Object { $_ }
            $Row.$col = ($pieces | ForEach-Object { Get-Token -Map $script:HostMap -Key $_ -Prefix 'esxi' -Suffix '.example.local' }) -join ', '
            continue
        }
        if ($ClusterColumns -contains $col) { $Row.$col = Get-Token -Map $script:ClusterMap -Key $val -Prefix 'cluster'; continue }
        if ($DcColumns -contains $col)      { $Row.$col = Get-Token -Map $script:DcMap      -Key $val -Prefix 'datacenter'; continue }
        if ($DsColumns -contains $col)      { $Row.$col = Get-DatastoreToken -Name $val -Type ''; continue }
        if ($IpColumns -contains $col)      { $Row.$col = Get-IpToken -Value $val; continue }
        if ($UuidColumns -contains $col)    { $Row.$col = Get-UuidToken -Value $val; continue }
        if ($FolderColumns -contains $col)  {
            if ($col -eq 'Path' -and $val -match '^\s*\[') {
                $Row.$col = Get-DatastorePathToken -Value $val
            } else {
                $Row.$col = Get-FolderToken -Value $val
            }
            continue
        }
        if ($MacColumns -contains $col)     { $Row.$col = '00:50:56:00:00:00'; continue }
        if ($UrlColumns -contains $col)     { $Row.$col = 'https://vcenter.example.local/sdk'; continue }
    }
    return $Row
}

$files = Get-ChildItem -LiteralPath $InputPath -Filter 'RVTools_tab*.csv' -File
Write-Host ("Sanitizing {0} RVTools CSVs from {1}" -f $files.Count, $InputPath) -ForegroundColor Cyan

function Import-RvCsv {
    # Import-Csv collapses case-variant duplicate columns. RVTools sometimes
    # emits both 'Campus' and 'campus' as separate custom-attribute columns.
    # Read the raw text, disambiguate duplicate headers, then parse.
    param([string]$Path)
    $enc = [System.Text.Encoding]::UTF8
    try {
        $text = [System.IO.File]::ReadAllText($Path, $enc)
    } catch {
        $enc = [System.Text.Encoding]::GetEncoding(1252)
        $text = [System.IO.File]::ReadAllText($Path, $enc)
    }
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $idx = $text.IndexOf($nl)
    if ($idx -lt 0) { return @() }
    $header = $text.Substring(0, $idx)
    $rest = $text.Substring($idx + $nl.Length)
    $cols = $header -split ','
    $seen = @{}
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $key = $cols[$i].ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $seen[$key]++
            $cols[$i] = ('{0}_dup{1}' -f $cols[$i], $seen[$key])
        } else {
            $seen[$key] = 1
        }
    }
    $fixed = ($cols -join ',') + $nl + $rest
    return @($fixed | ConvertFrom-Csv)
}

foreach ($file in $files) {
    $tabName = $file.BaseName -replace '^RVTools_tab',''
    Write-Host ("  {0,-20} ({1})" -f $file.Name, $tabName) -ForegroundColor DarkGray
    $rows = @(Import-RvCsv -Path $file.FullName)
    if ($rows.Count -eq 0) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $OutputPath $file.Name) -Force
        continue
    }
    $sanitized = foreach ($r in $rows) { Invoke-RowSanitize -Row $r -TabName $tabName }
    $destination = Join-Path $OutputPath $file.Name
    $sanitized | Export-Csv -LiteralPath $destination -NoTypeInformation -Encoding UTF8
}

Write-Host ("Sanitized files written to: {0}" -f $OutputPath) -ForegroundColor Green
Write-Host ("  VMs mapped        : {0}" -f $script:VmMap.Count)
Write-Host ("  Hosts mapped      : {0}" -f $script:HostMap.Count)
Write-Host ("  Clusters mapped   : {0}" -f $script:ClusterMap.Count)
Write-Host ("  Datastores mapped : {0}" -f $script:DatastoreMap.Count)
Write-Host ("  IPs mapped        : {0}" -f $script:IpMap.Count)
Write-Host ("  UUIDs mapped      : {0}" -f $script:UuidMap.Count)

if ($MapPath) {
    $map = [ordered]@{
        vms        = $script:VmMap
        hosts      = $script:HostMap
        clusters   = $script:ClusterMap
        datacenters= $script:DcMap
        datastores = $script:DatastoreMap
        ips        = $script:IpMap
        uuids      = $script:UuidMap
        folders    = $script:FolderMap
    }
    $map | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $MapPath -Encoding UTF8
    Write-Host ("Token map written to: {0}  (contains real->fake mappings, DO NOT SHARE)" -f $MapPath) -ForegroundColor Yellow
}
