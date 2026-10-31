# OBP metric tables: measured performance work

A load test, 21 measured demonstrations and the list of improvements they produced, all on a
pseudonymized copy of the [Open Bank Project](https://github.com/OpenBankProject/OBP-API) `metric`
and `metricarchive` tables, scaled to 5M + 15M rows. Every number in here was run on this data; the
reports say on what machine and with what limits.

| | What it is |
|---|---|
| [`IMPROVEMENTS.md`](IMPROVEMENTS.md) | 21 changes, each with what it buys, what it costs and how sure we are. Start here. |
| [`loadtest/`](loadtest/README.md) | pgbench: read, write and mixed scenarios at 1, 4, 8 and 16 clients, baseline against the `correlationid` index. |
| [`showcase/`](showcase/REPORT.md) | Common SQL optimization advice tested on this data, confirmed or corrected with measurements. |

The tooling that grew out of this work, for examining **any** table under its real usage, is its own
repository: [pglab](https://github.com/constantine2nd/postgresql-lab).

## The databases are disposable; the reports are not

Only `obp_mapped`, the real source, is irreplaceable, and nothing here writes to it. Everything else is
generated from it and can be deleted whenever the disk gets tight. The measurements live in the committed
reports, not in the databases that produced them.

```
obp_mapped                    the real source, read-only to all of this
  └─ obp_loadtest_base        loadtest/01_build_base.sh     ~7 GB, ~3 min
       └─ obp_showcase        showcase/00_setup.sh          ~6 GB, ~20 s (a createdb -T clone)
            └─ obp_loadtest   made and dropped by each run.sh scenario
```

To reclaim the space: `dropdb obp_showcase && dropdb obp_loadtest_base`, then rebuild top-down when
you next need them. `01_build_base.sh` checks there is room before it starts.

One thing a rebuild does not reproduce: `anonymize.sql` salts with a fresh `gen_random_uuid()` every
run and keeps no mapping, so the originals cannot be recovered, and neither can the previous
pseudonyms. A rebuilt database carries different fake identifiers than the ones quoted in the
existing reports. The measurements reproduce; the invented names do not.

## Where the numbers come from

Everything was measured on PostgreSQL 14.24, on a 4-core / 8-thread laptop with 16 GB RAM and an NVMe
disk, with `shared_buffers` at the 128 MB default. The server has since been upgraded to 18; the
reports describe the server they were measured on, and say so, until they are rerun.
