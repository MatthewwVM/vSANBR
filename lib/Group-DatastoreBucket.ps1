#Requires -Version 7.0

<#
.SYNOPSIS
    Classifies datastores into named buckets using a first-match-wins rule set.

.DESCRIPTION
    Evaluates each bucket rule in order against a datastore's Name and Type.
    Returns the first matching bucket (including 'exclude' status).

    Rule fields supported:
      matchName                     Regex matched against the datastore Name.
      matchNameCaseInsensitive      Boolean; if true, the regex is case-insensitive.
      matchType                     Exact (case-insensitive) match against Type.
      matchAll                      Matches anything (use as catch-all last rule).
      exclude                       Boolean; bucket is reported but excluded from totals.
      excludeReason                 Free text surfaced in output.
#>

function Test-DatastoreBucketRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [pscustomobject] $Rule
    )

    if ($Rule.PSObject.Properties.Name -contains 'matchAll' -and $Rule.matchAll) {
        return $true
    }

    if ($Rule.PSObject.Properties.Name -contains 'matchType' -and $Rule.matchType) {
        if ($Type -and ($Type -ieq [string]$Rule.matchType)) { return $true }
    }

    if ($Rule.PSObject.Properties.Name -contains 'matchName' -and $Rule.matchName) {
        $pattern = [string]$Rule.matchName
        $ci = $false
        if ($Rule.PSObject.Properties.Name -contains 'matchNameCaseInsensitive') {
            $ci = [bool]$Rule.matchNameCaseInsensitive
        }
        try {
            $opts = if ($ci) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }
            if ([System.Text.RegularExpressions.Regex]::IsMatch($Name, $pattern, $opts)) { return $true }
        } catch {
            Write-Warning "Invalid regex in bucket rule '$($Rule.name)': $pattern"
        }
    }

    return $false
}

function Get-DatastoreBucket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter()] [string] $Type = '',
        [Parameter(Mandatory)] [object[]] $BucketRules
    )

    foreach ($rule in $BucketRules) {
        if (Test-DatastoreBucketRule -Name $Name -Type $Type -Rule $rule) {
            return [pscustomobject]@{
                Name          = [string]$rule.name
                Exclude       = [bool]($rule.PSObject.Properties.Name -contains 'exclude' -and $rule.exclude)
                ExcludeReason = if ($rule.PSObject.Properties.Name -contains 'excludeReason') { [string]$rule.excludeReason } else { '' }
            }
        }
    }

    return [pscustomobject]@{
        Name          = 'Unclassified'
        Exclude       = $false
        ExcludeReason = ''
    }
}
