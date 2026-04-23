#Requires -Version 7.0

<#
.SYNOPSIS
    Generates a small, fully synthetic RVTools-shaped sample dataset for vSANBR.

.DESCRIPTION
    Writes RVTools_tab{vDatastore,vInfo,vDisk,vPartition}.csv into -OutputPath.
    These are the four tabs vSANBR consumes. All names, paths and numbers are
    fabricated for demonstration; no customer data is involved. The dataset is
    intentionally shaped to exercise every code path the tool has flags for:

        * vSAN FTT/RAID reversal + default-dedup flag
        * Powered-off VM flag
        * Orphan VM (Path references a datastore not in vDatastore)
        * Straddling VM (disks on two datastores)
        * Excluded local datastore bucket

.PARAMETER OutputPath
    Destination folder. Created if missing. Existing RVTools_tab*.csv files
    in it are overwritten.

.EXAMPLE
    ./New-SyntheticSample.ps1 -OutputPath ./samples/synthetic
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

function G { param([int] $Gib) return [int]($Gib * 1024) }

# -- vDatastore --------------------------------------------------------------
$datastores = @(
    [pscustomobject]@{ 'Name'='vsan-demo-01';   'Type'='vsan'; 'Cluster name'='cluster-demo-01'; '# Hosts'=4; 'Capacity MiB'=10485760; 'Provisioned MiB'=8388608; 'In Use MiB'=6291456; 'Free MiB'=4194304 }
    [pscustomobject]@{ 'Name'='vsan-demo-02';   'Type'='vsan'; 'Cluster name'='cluster-demo-02'; '# Hosts'=4; 'Capacity MiB'=10485760; 'Provisioned MiB'=5242880; 'In Use MiB'=4194304; 'Free MiB'=6291456 }
    [pscustomobject]@{ 'Name'='nimble-demo-01'; 'Type'='VMFS'; 'Cluster name'='cluster-demo-01'; '# Hosts'=2; 'Capacity MiB'=5242880;  'Provisioned MiB'=4194304; 'In Use MiB'=3145728; 'Free MiB'=2097152 }
    [pscustomobject]@{ 'Name'='nimble-demo-02'; 'Type'='VMFS'; 'Cluster name'='cluster-demo-02'; '# Hosts'=2; 'Capacity MiB'=5242880;  'Provisioned MiB'=1572864; 'In Use MiB'=1048576; 'Free MiB'=4194304 }
    [pscustomobject]@{ 'Name'='san-fc-demo-01'; 'Type'='VMFS'; 'Cluster name'='cluster-demo-01'; '# Hosts'=2; 'Capacity MiB'=2097152;  'Provisioned MiB'=1048576; 'In Use MiB'=819200;  'Free MiB'=1277952 }
    [pscustomobject]@{ 'Name'='local-ds-esx01'; 'Type'='VMFS'; 'Cluster name'='cluster-demo-01'; '# Hosts'=1; 'Capacity MiB'=512000;   'Provisioned MiB'=51200;   'In Use MiB'=51200;   'Free MiB'=460800 }
)
$datastores | Export-Csv -LiteralPath (Join-Path $OutputPath 'RVTools_tabvDatastore.csv') -NoTypeInformation

# -- vInfo -------------------------------------------------------------------
$vms = @(
    [pscustomobject]@{ 'VM'='vm-app-01';    'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=4; 'Memory'=8192;  'Disks'=1; 'In Use MiB'=(G 200);  'Provisioned MiB'=(G 250);  'Path'='[vsan-demo-01] vm-app-01/vm-app-01.vmx';         'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-01'; 'OS according to the VMware Tools'='Ubuntu Linux (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-app-02';    'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=4; 'Memory'=8192;  'Disks'=1; 'In Use MiB'=(G 300);  'Provisioned MiB'=(G 400);  'Path'='[vsan-demo-01] vm-app-02/vm-app-02.vmx';         'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-01'; 'OS according to the VMware Tools'='Ubuntu Linux (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-db-01';     'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=8; 'Memory'=32768; 'Disks'=2; 'In Use MiB'=(G 800);  'Provisioned MiB'=(G 1000); 'Path'='[vsan-demo-01] vm-db-01/vm-db-01.vmx';           'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-01'; 'OS according to the VMware Tools'='Red Hat Enterprise Linux 8 (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-web-01';    'Powerstate'='poweredOff'; 'Template'=$false; 'CPUs'=2; 'Memory'=4096;  'Disks'=1; 'In Use MiB'=(G 150);  'Provisioned MiB'=(G 200);  'Path'='[vsan-demo-02] vm-web-01/vm-web-01.vmx';         'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-02'; 'OS according to the VMware Tools'='Ubuntu Linux (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-util-01';   'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=2; 'Memory'=4096;  'Disks'=1; 'In Use MiB'=(G 100);  'Provisioned MiB'=(G 150);  'Path'='[vsan-demo-02] vm-util-01/vm-util-01.vmx';       'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-02'; 'OS according to the VMware Tools'='Ubuntu Linux (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-bi-01';     'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=4; 'Memory'=16384; 'Disks'=1; 'In Use MiB'=(G 250);  'Provisioned MiB'=(G 300);  'Path'='[vsan-demo-02] vm-bi-01/vm-bi-01.vmx';           'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-02'; 'OS according to the VMware Tools'='Microsoft Windows Server 2019 (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-file-01';   'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=4; 'Memory'=8192;  'Disks'=2; 'In Use MiB'=(G 1024); 'Provisioned MiB'=(G 1500); 'Path'='[nimble-demo-01] vm-file-01/vm-file-01.vmx';     'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-01'; 'OS according to the VMware Tools'='Microsoft Windows Server 2022 (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-backup-01'; 'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=4; 'Memory'=8192;  'Disks'=1; 'In Use MiB'=(G 400);  'Provisioned MiB'=(G 500);  'Path'='[nimble-demo-02] vm-backup-01/vm-backup-01.vmx'; 'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-02'; 'OS according to the VMware Tools'='Ubuntu Linux (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-legacy-01'; 'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=2; 'Memory'=4096;  'Disks'=1; 'In Use MiB'=(G 500);  'Provisioned MiB'=(G 600);  'Path'='[san-fc-demo-01] vm-legacy-01/vm-legacy-01.vmx'; 'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-01'; 'OS according to the VMware Tools'='CentOS 7 (64-bit)' }
    [pscustomobject]@{ 'VM'='vm-orphan-01'; 'Powerstate'='poweredOn';  'Template'=$false; 'CPUs'=2; 'Memory'=4096;  'Disks'=1; 'In Use MiB'=(G 100);  'Provisioned MiB'=(G 150);  'Path'='[decommissioned-ds] vm-orphan-01/vm-orphan-01.vmx'; 'Datacenter'='dc-demo'; 'Cluster'='cluster-demo-01'; 'OS according to the VMware Tools'='Ubuntu Linux (64-bit)' }
)
$vms | Export-Csv -LiteralPath (Join-Path $OutputPath 'RVTools_tabvInfo.csv') -NoTypeInformation

# -- vDisk -------------------------------------------------------------------
$disks = @(
    [pscustomobject]@{ 'VM'='vm-app-01';    'Disk'='Hard disk 1'; 'Capacity MiB'=(G 250);  'Thin'=$true; 'Path'='[vsan-demo-01] vm-app-01/vm-app-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-app-02';    'Disk'='Hard disk 1'; 'Capacity MiB'=(G 400);  'Thin'=$true; 'Path'='[vsan-demo-01] vm-app-02/vm-app-02.vmdk' }
    [pscustomobject]@{ 'VM'='vm-db-01';     'Disk'='Hard disk 1'; 'Capacity MiB'=(G 100);  'Thin'=$true; 'Path'='[vsan-demo-01] vm-db-01/vm-db-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-db-01';     'Disk'='Hard disk 2'; 'Capacity MiB'=(G 900);  'Thin'=$true; 'Path'='[vsan-demo-01] vm-db-01/vm-db-01_1.vmdk' }
    [pscustomobject]@{ 'VM'='vm-web-01';    'Disk'='Hard disk 1'; 'Capacity MiB'=(G 200);  'Thin'=$true; 'Path'='[vsan-demo-02] vm-web-01/vm-web-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-util-01';   'Disk'='Hard disk 1'; 'Capacity MiB'=(G 150);  'Thin'=$true; 'Path'='[vsan-demo-02] vm-util-01/vm-util-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-bi-01';     'Disk'='Hard disk 1'; 'Capacity MiB'=(G 300);  'Thin'=$true; 'Path'='[vsan-demo-02] vm-bi-01/vm-bi-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-file-01';   'Disk'='Hard disk 1'; 'Capacity MiB'=(G 500);  'Thin'=$true; 'Path'='[nimble-demo-01] vm-file-01/vm-file-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-file-01';   'Disk'='Hard disk 2'; 'Capacity MiB'=(G 1000); 'Thin'=$true; 'Path'='[nimble-demo-02] vm-file-01/vm-file-01_1.vmdk' }
    [pscustomobject]@{ 'VM'='vm-backup-01'; 'Disk'='Hard disk 1'; 'Capacity MiB'=(G 500);  'Thin'=$true; 'Path'='[nimble-demo-02] vm-backup-01/vm-backup-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-legacy-01'; 'Disk'='Hard disk 1'; 'Capacity MiB'=(G 600);  'Thin'=$false;'Path'='[san-fc-demo-01] vm-legacy-01/vm-legacy-01.vmdk' }
    [pscustomobject]@{ 'VM'='vm-orphan-01'; 'Disk'='Hard disk 1'; 'Capacity MiB'=(G 150);  'Thin'=$true; 'Path'='[decommissioned-ds] vm-orphan-01/vm-orphan-01.vmdk' }
)
$disks | Export-Csv -LiteralPath (Join-Path $OutputPath 'RVTools_tabvDisk.csv') -NoTypeInformation

# -- vPartition (guest-OS view; ~85% of VM InUse on average) -----------------
$parts = @(
    [pscustomobject]@{ 'VM'='vm-app-01';    'Disk'='/';       'Capacity MiB'=(G 200);  'Consumed MiB'=(G 170); 'Free MiB'=(G 30) }
    [pscustomobject]@{ 'VM'='vm-app-02';    'Disk'='/';       'Capacity MiB'=(G 300);  'Consumed MiB'=(G 255); 'Free MiB'=(G 45) }
    [pscustomobject]@{ 'VM'='vm-db-01';     'Disk'='/';       'Capacity MiB'=(G 80);   'Consumed MiB'=(G 60);  'Free MiB'=(G 20) }
    [pscustomobject]@{ 'VM'='vm-db-01';     'Disk'='/data';   'Capacity MiB'=(G 720);  'Consumed MiB'=(G 620); 'Free MiB'=(G 100) }
    [pscustomobject]@{ 'VM'='vm-web-01';    'Disk'='/';       'Capacity MiB'=(G 150);  'Consumed MiB'=(G 128); 'Free MiB'=(G 22) }
    [pscustomobject]@{ 'VM'='vm-util-01';   'Disk'='/';       'Capacity MiB'=(G 100);  'Consumed MiB'=(G 85);  'Free MiB'=(G 15) }
    [pscustomobject]@{ 'VM'='vm-bi-01';     'Disk'='C:\';     'Capacity MiB'=(G 250);  'Consumed MiB'=(G 213); 'Free MiB'=(G 37) }
    [pscustomobject]@{ 'VM'='vm-file-01';   'Disk'='E:\';     'Capacity MiB'=(G 1024); 'Consumed MiB'=(G 870); 'Free MiB'=(G 154) }
    [pscustomobject]@{ 'VM'='vm-backup-01'; 'Disk'='/backup'; 'Capacity MiB'=(G 400);  'Consumed MiB'=(G 340); 'Free MiB'=(G 60) }
    [pscustomobject]@{ 'VM'='vm-legacy-01'; 'Disk'='/';       'Capacity MiB'=(G 500);  'Consumed MiB'=(G 425); 'Free MiB'=(G 75) }
    [pscustomobject]@{ 'VM'='vm-orphan-01'; 'Disk'='/';       'Capacity MiB'=(G 100);  'Consumed MiB'=(G 85);  'Free MiB'=(G 15) }
)
$parts | Export-Csv -LiteralPath (Join-Path $OutputPath 'RVTools_tabvPartition.csv') -NoTypeInformation

Write-Host ("Wrote synthetic sample to {0}" -f $OutputPath)
Write-Host ("  vDatastore : {0} rows" -f $datastores.Count)
Write-Host ("  vInfo      : {0} rows" -f $vms.Count)
Write-Host ("  vDisk      : {0} rows" -f $disks.Count)
Write-Host ("  vPartition : {0} rows" -f $parts.Count)
