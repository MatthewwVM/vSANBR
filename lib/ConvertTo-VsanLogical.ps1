#Requires -Version 7.0

<#
.SYNOPSIS
    Converts vSAN 'In Use' capacity to logical data by removing FTT/RAID overhead
    and re-applying the dedup/compression ratio reported by the source.

.DESCRIPTION
    vSAN reports 'In Use' as the physical bytes consumed on the cache tier,
    which INCLUDES replica/parity overhead AND reflects the post-dedup/compression
    footprint. To recover the logical data the customer is actually storing:

        Logical = InUse / FttMultiplier * DedupCompressionRatio

    FttMultiplier lookup (VMware, Demystifying Capacity Reporting in vSAN):
        FTT=0                       1.00
        FTT=1 RAID-1 (mirror)       2.00
        FTT=1 RAID-5 (3+1 EC)       1.33
        FTT=2 RAID-1 (3 copies)     3.00
        FTT=2 RAID-6 (4+2 EC)       1.50
        FTT=3 RAID-1 (4 copies)     4.00
#>

function Get-VsanFttMultiplier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Ftt,
        [Parameter(Mandatory)] [int] $Raid
    )

    switch ("$Ftt/$Raid") {
        '0/0' { return 1.0 }
        '1/1' { return 2.0 }
        '1/5' { return [math]::Round(4/3, 6) }
        '2/1' { return 3.0 }
        '2/6' { return 1.5 }
        '3/1' { return 4.0 }
        default {
            throw "Unsupported vSAN policy combination FTT=$Ftt RAID=$Raid. Supported: 0/0, 1/1, 1/5, 2/1, 2/6, 3/1."
        }
    }
}

function Get-VsanPolicyForDatastore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DatastoreName,
        [Parameter()] [string] $ClusterName = '',
        [Parameter(Mandatory)] [pscustomobject] $VsanConfig
    )

    if ($VsanConfig.PSObject.Properties.Name -contains 'overrides' -and $VsanConfig.overrides) {
        foreach ($ov in $VsanConfig.overrides) {
            $matchName = if ($ov.PSObject.Properties.Name -contains 'matchDatastoreName') { [string]$ov.matchDatastoreName } else { '' }
            $matchCluster = if ($ov.PSObject.Properties.Name -contains 'matchClusterName') { [string]$ov.matchClusterName } else { '' }
            if ($matchName -and $DatastoreName -ieq $matchName) {
                return $ov
            }
            if ($matchCluster -and $ClusterName -ieq $matchCluster) {
                return $ov
            }
        }
    }

    return $VsanConfig.defaultPolicy
}

function ConvertTo-VsanLogicalMiB {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [long] $InUseMiB,
        [Parameter(Mandatory)] [int] $Ftt,
        [Parameter(Mandatory)] [int] $Raid,
        [Parameter()] [double] $DedupCompressionRatio = 1.0
    )

    $mult = Get-VsanFttMultiplier -Ftt $Ftt -Raid $Raid
    if ($DedupCompressionRatio -le 0) { throw "DedupCompressionRatio must be > 0" }
    $logical = [double]$InUseMiB / $mult * $DedupCompressionRatio
    return [long][math]::Round($logical, 0)
}

function ConvertTo-TiB {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $MiB,
        [Parameter()] [int] $Digits = 2
    )
    return [math]::Round($MiB / 1024.0 / 1024.0, $Digits)
}
