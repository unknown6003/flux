# Empty-profile Mac sample

One paired diagnostic ran on 9 November 2026. It is not a release benchmark.
Each app had a 20-second warmup, then 13 observations over 60 seconds.

| Metric | Installed 0.21.35 build 62 | Candidate 0.22.0 build 64 |
| --- | ---: | ---: |
| Sample start UTC | 04:21:24.910 | 04:22:45.820 |
| Duration, seconds | 60.014 | 60.010 |
| CPU time, milliseconds | 1.399 | 2.020 |
| Mean RSS, MiB | 70.81 | 49.73 |
| Peak RSS, MiB | 70.86 | 49.75 |
| Mean physical footprint, MiB | 15.13 | 13.81 |
| Interrupt wakeups | 3 | 3 |
| Idle wakeups | 0 | 0 |

The candidate source was e2828c5746fc50d530680e5febc2d6f18814a77c.
Its archive was 1772121 bytes, SHA256
b689a133f52464b0d034b419b98b7775c5534fbed20935930cb3894cb29726f3.
Strict signing and the expected release certificate passed before installation.

## Workload and limits

Both complete prelaunch preference profiles matched. Notch, automatic update
checks and analytics were off. Hidden and Always Hidden lists were empty;
other layout fields were preserved. The candidate's position backend was
paused by default. This does not measure normal hiding or full feature parity.

Each sample had one attributed process. Descendants were rediscovered at each
observation, with PID-start identity checks. Five pre-existing Perl processes
had PPID 1 and could not be attributed. They were excluded from both samples
and left running. Processes that start and end between observations are not
measured. RSS totals can count shared pages more than once.

The sampler's full-duration disposable control observed children arriving and
one leaving. CPU units were calibrated against a bounded one-thread burn:
getrusage reported 1.996522 seconds, while the raw counter with Mach timebase
125/3 gave 1.99653675 seconds. The relative difference was 0.00000739. Raw CPU
counters on this Mac are therefore treated as Mach ticks, not nanoseconds.
The parent recomputed the duration, CPU and memory means from both CSVs.

The candidate used less memory in this pair. CPU costs were tiny for both.
There is no variance estimate or repeatability result. This is not a whole
system result, an analytics on/off comparison, or evidence that hiding works.

## Restoration

The original app's complete file/symlink manifest, executable hash, strict
signature, version and build matched after restoration. One running process
had the exact original app and executable URLs. The post-quit preference
baseline matched after a three-way restore, with no concurrent conflicts or
relaunch deltas. Clipboard contents and change count matched.

Shelf asset and manifest hashes matched. Saved clipboard data matched its
post-quit safety copy. Session timestamps changed; state-file bytes were not
identical. No content file was overwritten to hide that difference. Temporary
application slots were removed. Original backups remain private on the Mac.

## Evidence

The sanitized archive contains CSVs, calibration, control, transaction source
and restoration summary. Its SHA256 is
5f65a86d4b49234ea074687c2f84c0676176023cca92bbd66a92ae9aafca2088.
Local ignored evidence: build/benchmark-empty/.

[Download sanitized evidence](https://templink.bdwy.xyz/media/1794803971-1794890371-e5adae532cf8f3783752f19f.bin).
The link expires; the recorded hashes identify the retained local evidence.
The runnable Mac transaction is /tmp/flux-benchmark-20261109-0409/transaction.py.

[Apple XNU counter source](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/osfmk/kern/bsd_kern.c)
copies powerinfo CPU totals into the rusage fields. Calibration establishes
the conversion for the tested Mac; the source alone does not establish units.
