# vSANBR — vSAN Bloat Reduce

A PowerShell tool that reverses vSAN's capacity overhead out of an RVTools
export so you can see the **actual logical data** an environment is holding.
The output is a single formatted `.xlsx` workbook that shows the headline
logical TiB number, per-bucket breakdowns (vSAN, Nimble, VMFS, NFS, local),
and the assumptions used so every number is auditable.

## Why

vSAN reports "In Use" capacity as **post-dedup/compression bytes consumed on
the cache tier, including replica/parity overhead**. That value is not the
amount of data a replacement array has to store  it is the physical footprint
of that data on a vSAN with a specific storage policy. This generally leads to
customers and partners overestimating storage capacity for new storage arrays.

If you take the number straight out of vCenter / RVTools, you will either
oversize or undersize depending on the replacement array's data-reduction
characteristics. vSANBR applies the right inverse:

```
Logical = (InUse / FttMultiplier) * DedupCompressionRatio
```

| FTT | RAID         | Multiplier |
| --- | ------------ | ---------- |
| 0   | 0            | 1.00       |
| 1   | 1 (mirror)   | 2.00       |
| 1   | 5 (EC 3+1)   | 1.33       |
| 2   | 1 (3 copies) | 3.00       |
| 2   | 6 (EC 4+2)   | 1.50       |
| 3   | 1 (4 copies) | 4.00       |

Non-vSAN datastores (Nimble, VMFS, NFS, local) are counted at their reported
"In Use" value. Excluded buckets (local ESXi scratch, boot devices) are
reported but not added to the total.

## What it reads

vSANBR consumes four tabs from the RVTools export:

| Tab          | Purpose                                                                    |
| ------------ | -------------------------------------------------------------------------- |
| `vDatastore` | Bucket classification, vSAN/VMFS/NFS type, cluster mapping, capacity sums  |
| `vInfo`      | **Primary sizing source.** Per-VM `In Use MiB` drives the headline         |
| `vDisk`      | Straddle advisory (VMs whose disks span multiple datastores)               |
| `vPartition` | Guest-OS consumed crosscheck vs. the headline                              |

The headline is driven by `vInfo."In Use MiB"` (which is VMware's
`summary.storage.committed` — the bytes that move when a VM is evacuated,
including VMDKs, snapshots, `.vswp` swap, and VM metadata). Each VM's primary
datastore is resolved from the `[datastore-name]` token in its `Path`, and
if that datastore is a vSAN type the FTT/RAID/dedup reversal is applied to
that VM's In Use.

## Requirements

- PowerShell **7.0+** (cross-platform; Windows, macOS, Linux, WSL)
- `ImportExcel` module (installed automatically on first run or via `Install-Module ImportExcel`)
- An RVTools export — either the folder of `RVTools_tab*.csv` files or the single `.xlsx` workbook

## Install

```powershell
git clone https://github.com/MatthewwVM/vSANBR.git
cd vSANBR
Install-Module ImportExcel -Scope CurrentUser
```

## Usage

### Simplest case (default assumptions)

```powershell
./vSANBR.ps1 -InputPath C:\RVTools\customer -OutputPath C:\tmp\sizing.xlsx
```

Defaults to FTT=1, RAID-5, 1.5x dedup/compression. The default ratio is
**flagged** in the workbook so you aren't surprised.

### Customer has told you the real ratio

```powershell
./vSANBR.ps1 -InputPath .\rvtools -DedupCompressionRatio 1.78
```

The workbook will show `CUSTOMER_REPORTED` instead of `DEFAULT_ASSUMED_AVERAGE`
in the Assumptions sheet.

### Mirrored vSAN (FTT=1 RAID-1)

```powershell
./vSANBR.ps1 -InputPath .\rvtools -Ftt 1 -Raid 1 -DedupCompressionRatio 1.0
```

### Per-cluster overrides

Copy `samples/sample-config.json`, edit, then pass it:

```powershell
./vSANBR.ps1 -InputPath .\rvtools -ConfigPath .\my-customer.json
```

This supports a different FTT / RAID / dedup ratio per datastore or cluster
name, which is what you need when a customer mixes policies.

### Try it against the included synthetic sample

```powershell
./vSANBR.ps1 -InputPath ./samples/synthetic -OutputPath /tmp/demo.xlsx
```

## Output workbook

| Sheet          | Contents                                                                      |
| -------------- | ----------------------------------------------------------------------------- |
| `Summary`      | Headline logical TiB, source, VM counts, powered-off / orphan / straddle tallies |
| `BucketRollup` | Per-bucket totals: datastore count, VM count, Capacity / VM InUse / Logical TiB  |
| `Datastores`   | Every datastore with its bucket, type, applied policy, VM rollup, logical TiB |
| `Vms`          | Per-VM breakdown: datastore, bucket, FTT/RAID/ratio, InUse, provisioned, logical |
| `Crosscheck`   | Headline TiB vs vPartition guest-consumed TiB, delta, delta %                 |
| `Straddlers`   | Advisory: VMs whose disks span two or more datastores (from vDisk)            |
| `Assumptions`  | Default vSAN policy plus any overrides that matched, with source tags         |
| `Flags`        | Severity-tagged list of everything worth reviewing (see below)                |

## Flags

| Flag                  | When it fires                                                                        |
| --------------------- | ------------------------------------------------------------------------------------ |
| `DEFAULT_DEDUP_RATIO` | At least one vSAN datastore used the built-in 1.5x assumption. Replace with the customer-reported ratio for accuracy. |
| `POWERED_OFF_VMS`     | The environment has powered-off VMs. Their `In Use MiB` excludes swap (`.vswp`); confirm they are in migration scope. |
| `ORPHAN_VMS`          | VMs whose `Path` references a datastore not present in `vDatastore`. Counted at reported In Use with no vSAN reversal. |
| `STRADDLING_VMS`      | VMs with disks on two or more datastores. Advisory only; does not affect the headline for full-evacuation sizing. |
| `GUEST_RECLAIM_GAP`   | The vPartition crosscheck is more than 30% below the headline. Usually indicates thin-provisioning reclaim lag or orphan VMDKs. |

## Sanitizing customer data for a demo

`scripts/Invoke-RvToolsSanitize.ps1` walks an RVTools export and masks VM
names, hosts, clusters, datastores, IPs, UUIDs, and free-text fields while
preserving every numeric value and the relationships between rows. Datastore
names are rewritten with a type-aware prefix (`vsan-ds-`, `nimble-ds-`,
`local-ds-`) so bucket classification still works against the sanitized copy.
The `[datastore-name]` token inside VM and disk `Path` values is rewritten
with the same token so the `vInfo`→datastore→policy join still resolves.

```powershell
./scripts/Invoke-RvToolsSanitize.ps1 `
    -InputPath  C:\RVTools\customer `
    -OutputPath .\my-sanitized-export
```

## Synthetic sample

`samples/synthetic/` contains a fabricated RVTools-shaped dataset (6 datastores,
10 VMs, 12 disks, 11 partitions) with no customer origin. It exercises every
classification and flag path. Regenerate it any time with:

```powershell
./scripts/New-SyntheticSample.ps1 -OutputPath ./samples/synthetic
```

## Example output

Running against the included synthetic sample with default assumptions:

```
=== Headline ===
Logical TiB (migration target): 3.95
  Source: vInfo 'In Use MiB' (per VM), vSAN FTT/RAID overhead removed
  VMs: 10 analysed / 10 included / 1 powered off / 1 orphan

Bucket                DatastoreCount IncludedCount ExcludedCount VmCount CapacityTiB VmInUseTiB LogicalTiB
Local VMFS (excluded)              1             0             1       0        0.49       0.00       0.00
Nimble                             2             2             0       2       10.00       1.39       1.39
Other SAN (VMFS)                   1             1             0       1        2.00       0.49       0.49
vSAN                               2             2             0       6       20.00       1.76       1.98

Crosscheck (vPartition):
  Headline:             3.95 TiB
  Guest consumed:       3.17 TiB
  Delta:                0.78 TiB (+19.7%)

Flags:
  DEFAULT_DEDUP_RATIO: ...
  POWERED_OFF_VMS: 1 VMs are powered off ...
  ORPHAN_VMS: 1 VMs in vInfo had a Path whose datastore is not listed in vDatastore ...
  STRADDLING_VMS: 1 VMs have disks on >=2 datastores ...
```

## License

MIT
