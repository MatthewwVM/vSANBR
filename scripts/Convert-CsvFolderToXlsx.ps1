#Requires -Version 7.0
#Requires -Modules ImportExcel

<#
.SYNOPSIS
    Bundles a folder of RVTools_tab*.csv files into a single RVTools-style .xlsx workbook.

.DESCRIPTION
    Used for round-trip testing of the xlsx reader path against the same data the CSV
    reader path consumes. Sheet names are derived from the file name by stripping the
    'RVTools_tab' prefix (e.g. RVTools_tabvDatastore.csv -> vDatastore).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $InputPath,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir '..' 'lib' 'Read-RvInput.ps1')

if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

$files = Get-ChildItem -LiteralPath $InputPath -Filter 'RVTools_tab*.csv' -File
foreach ($f in $files) {
    $sheet = $f.BaseName -replace '^RVTools_tab', ''
    $rows = Read-RvCsvSafely -Path $f.FullName
    if ($rows.Count -eq 0) {
        Write-Verbose "Skipping empty sheet '$sheet'"
        continue
    }
    Write-Host ("Writing sheet {0,-14} ({1} rows)" -f $sheet, $rows.Count)
    $rows | Export-Excel -Path $OutputPath -WorksheetName $sheet -ClearSheet
}

Write-Host "Wrote $OutputPath"
