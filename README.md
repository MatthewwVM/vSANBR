# vSANBR — vSAN Bloat Reduce

A PowerShell tool that reverses vSAN's capacity overhead out of an RVTools
export so you can see the **actual logical data** an environment is holding.
The output is a single formatted `.xlsx` workbook that shows the headline
logical TiB number, per-bucket breakdowns (vSAN, Nimble, VMFS, NFS, local),
and the assumptions used so every number is auditable.

## Why

vSAN reports per-VM "In Use" capacity inclusive of **replica/parity
overhead** from the storage policy. That value is not the amount of data a
replacement array has to store - it is the physical footprint of the data on
a vSAN with a specific FTT/RAID policy. Taking the number straight out of
vCenter / RVTools oversizes the target array by the FTT multiplier.

vSANBR reverses that overhead:

```
Logical = InUse / FttMultiplier
```

> **Note on dedup/compression.** Previous logic assumed vInfo 'In Use MiB'
> was post-dedup/compression and multiplied the result by an assumed dedup
> ratio. That assumption is under verification: dedup is a cluster-scope
> property that cannot be cleanly attributed per-VM, so the per-VM committed
> field is believed NOT to include dedup savings. Until a `VsanQuerySpaceUsage`
> ground-truth run confirms or refutes this, the dedup factor is surfaced in
> the workbook and CLI but **not applied to the logical total**.

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

Defaults to FTT=1, RAID-5. The `-DedupCompressionRatio` default of 1.5x is
configured but **not applied** to the headline (see note on dedup above);
the ratio is surfaced in the workbook as advisory metadata only.

### Customer has told you the real ratio

```powershell
./vSANBR.ps1 -InputPath .\rvtools -DedupCompressionRatio 1.78
```

The workbook will show `CUSTOMER_REPORTED` instead of `DEFAULT_ASSUMED_AVERAGE`
in the Assumptions sheet. The ratio is recorded but does not modify the
logical total while the dedup behaviour of `summary.storage.committed` is
under verification.

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

## Finding vSAN inputs in vCenter

RVTools does not export the vSAN dedup/compression ratio or the storage policy
assignments, so these have to be read out of vCenter by hand. The two inputs
that matter most for sizing accuracy are (1) the actual dedup+compression ratio
per cluster, and (2) which policy the bulk of the data is sitting on.

### Dedup and compression ratio (per cluster)

vSAN reports dedup/compression as a single combined ratio. Grab it per cluster
and feed it back in via `-DedupCompressionRatio` or a config override.

1. vSphere Client &rarr; **Hosts and Clusters** &rarr; select the vSAN cluster.
2. **Monitor** tab &rarr; **vSAN** &rarr; **Capacity**.
3. Look at the **Data reduction** (or **Deduplication and compression overview**)
   panel. The number shown is `X.XXx` (for example `1.78x`). That is the value
   to pass to vSANBR.
4. If the cluster has the feature disabled, the panel will say so and the
   ratio is effectively `1.0`.

Notes:
- vSAN ESA ("Express Storage Architecture") always reports compression-only;
  OSA clusters with dedup+compression enabled report the combined number.
- The ratio is not constant. If the customer has a long-running environment,
  it is more meaningful than a freshly-ingested one. If multiple clusters
  differ meaningfully, use a config file with per-cluster overrides rather
  than one flat `-DedupCompressionRatio`.

### Identifying which policies hold the most data

Not every VM is on the default policy. Before you assume `FTT=1 RAID=5`, find
out where the data actually lives.

1. vSphere Client &rarr; **Policies and Profiles** &rarr; **VM Storage Policies**.
2. Sort/scan the list for vSAN policies (they will have vSAN-specific rules:
   Failures to tolerate, Number of disk stripes, etc.).
3. Click a policy &rarr; **VMs** tab &rarr; shows every VM currently assigned to
   that policy. Count rows, or sort by `Provisioned` / `Used` to see which
   policy is carrying the most capacity.
4. Click the **Check compliance** / **Rules** tab to read the FTT and RAID
   values the policy enforces (e.g. `Failures to tolerate: 1 failure - RAID-5
   (Erasure Coding)`).

A faster alternative when a cluster has many policies:

1. **Hosts and Clusters** &rarr; select the vSAN cluster.
2. **Monitor** &rarr; **vSAN** &rarr; **Virtual Objects**.
3. Group by **Storage Policy**. The policies with the largest object counts
   and used capacity are the ones that matter; smaller policies can be
   covered by the default reversal without introducing meaningful error.

Feed the dominant policies into `samples/sample-config.json` as overrides
keyed on datastore name (or cluster name if the datastore names are opaque).
The `Assumptions` sheet in the output workbook will show exactly which policy
was applied to which datastore, so you can confirm the overrides matched.

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
| `DEDUP_NOT_APPLIED`   | Always fires. Reminder that the headline removes FTT/RAID only; dedup/compression is surfaced but not applied to the total. |
| `DEFAULT_DEDUP_RATIO` | The built-in 1.5x ratio is configured. Advisory only while dedup handling is under verification. |
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
