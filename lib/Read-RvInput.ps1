#Requires -Version 7.0
#Requires -Modules ImportExcel

<#
.SYNOPSIS
    Reads an RVTools export — either a folder containing RVTools_tab*.csv files or
    a single native RVTools .xlsx workbook — and returns a hashtable of tabs.

.DESCRIPTION
    Returns @{ Datastore=[pscustomobject[]]; Info=[pscustomobject[]]; Disk=[pscustomobject[]]; Partition=[pscustomobject[]] }.
    Info drives the headline, Datastore provides type/policy lookup, Partition feeds
    the guest-consumed crosscheck, Disk is optional and only used for the straddle
    advisory sheet. CSV encoding falls back to Windows-1252 when UTF-8 parsing fails.
#>

function Read-RvCsvSafely {
    # RVTools exports occasionally contain columns that differ only in case
    # (e.g. 'Campus' and 'campus' both present). Import-Csv treats property
    # names case-insensitively and throws 'The member X is already present.'
    # We read the raw text, disambiguate duplicate headers with a _dupN suffix,
    # then parse via ConvertFrom-Csv.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $encoders = @(
        [System.Text.Encoding]::UTF8,
        [System.Text.Encoding]::GetEncoding(1252)
    )
    $text = $null
    foreach ($enc in $encoders) {
        try { $text = [System.IO.File]::ReadAllText($Path, $enc); break } catch { continue }
    }
    if (-not $text) {
        Write-Warning "Failed to read $Path"
        return @()
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
        if ($seen.ContainsKey($key)) { $seen[$key]++; $cols[$i] = ('{0}_dup{1}' -f $cols[$i], $seen[$key]) }
        else { $seen[$key] = 1 }
    }
    $fixed = ($cols -join ',') + $nl + $rest
    try {
        return @($fixed | ConvertFrom-Csv)
    } catch {
        Write-Warning "Failed to parse $Path after header dedup: $_"
        return @()
    }
}

function Read-RvFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $map = [ordered]@{
        Datastore = 'RVTools_tabvDatastore.csv'
        Info      = 'RVTools_tabvInfo.csv'
        Disk      = 'RVTools_tabvDisk.csv'
        Partition = 'RVTools_tabvPartition.csv'
    }

    $result = @{}
    foreach ($key in $map.Keys) {
        $file = Join-Path -Path $Path -ChildPath $map[$key]
        $result[$key] = Read-RvCsvSafely -Path $file
        Write-Verbose "Loaded $key from $($map[$key]): $($result[$key].Count) rows"
    }
    return $result
}

function Read-RvXlsx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }

    $map = [ordered]@{
        Datastore = 'vDatastore'
        Info      = 'vInfo'
        Disk      = 'vDisk'
        Partition = 'vPartition'
    }

    $sheetInfo = Get-ExcelSheetInfo -Path $Path
    $available = @($sheetInfo | ForEach-Object { $_.Name })

    $result = @{}
    foreach ($key in $map.Keys) {
        $sheetName = $map[$key]
        if ($available -contains $sheetName) {
            try {
                $result[$key] = @(Import-RvExcelSheet -Path $Path -WorksheetName $sheetName)
                Write-Verbose "Loaded $key from sheet '$sheetName': $($result[$key].Count) rows"
            } catch {
                Write-Warning "Failed to read sheet '$sheetName': $_"
                $result[$key] = @()
            }
        } else {
            $result[$key] = @()
            Write-Verbose "Sheet '$sheetName' not present in workbook."
        }
    }
    return $result
}

function Import-RvExcelSheet {
    # Mirrors the CSV-path header-dedup behaviour for xlsx sheets. RVTools
    # workbooks occasionally contain columns that differ only in case
    # (e.g. 'Campus' / 'campus'); Import-Excel's default path builds
    # PSCustomObjects and throws on duplicate property names.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $WorksheetName
    )

    $headerRow = @(Import-Excel -Path $Path -WorksheetName $WorksheetName -NoHeader -EndRow 1)
    if ($headerRow.Count -eq 0) { return @() }

    $raw = $headerRow[0]
    $cols = @()
    foreach ($p in $raw.PSObject.Properties) {
        $v = if ($null -ne $p.Value) { [string]$p.Value } else { '' }
        $cols += $v
    }

    $seen = @{}
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $name = $cols[$i]
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Column$($i + 1)"; $cols[$i] = $name }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $seen[$key]++; $cols[$i] = ('{0}_dup{1}' -f $name, $seen[$key]) }
        else { $seen[$key] = 1 }
    }

    return @(Import-Excel -Path $Path -WorksheetName $WorksheetName -HeaderName $cols -StartRow 2)
}

function Read-RvInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path

    if (Test-Path -LiteralPath $resolved -PathType Container) {
        Write-Verbose "Input detected as directory."
        return Read-RvFolder -Path $resolved
    }

    $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($ext -eq '.xlsx' -or $ext -eq '.xlsm') {
        Write-Verbose "Input detected as Excel workbook."
        return Read-RvXlsx -Path $resolved
    }

    throw "Unrecognized input: '$Path'. Provide a folder of RVTools CSVs or an .xlsx workbook."
}
