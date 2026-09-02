---
description: What is the state of the world — processes, deployed build, flags, index freshness, fault budget, what bound
argument-hint: [section, e.g. build flags index]
---

Run `python tools/doctor.py $ARGUMENTS` and report what it says.

This is the **first thing to run before debugging anything**, because most dead
ends in this project are state you could have read in one line: which build is
actually deployed, which flags are on, whether the name index is stale, how much
of the inspector's 8-fault budget is already spent, and what actually bound this
run.

Sections: `procs build flags index faults bound raid backups` (default: all).

Read it critically rather than reciting it:

- **`UNKNOWN` means unknown.** The tool says UNKNOWN rather than guessing; do not
  turn that into a claim in your summary.
- **The host truncates its log at every start**, so the log describes exactly one
  run. If no client is running, the log is a *finished* run and says nothing
  about the present — a line in it is not evidence about now.
- **A stale name index is dangerous, not merely unhelpful**: a wrong-but-mapped
  address is the corruption case the safety rules exist to prevent. `FRESH`
  means the build stamp and cross-checks agree with the deployed
  `GameAssembly.dll`.
- **Deployed-vs-local mismatch is worth flagging out loud.** It is normal for the
  deployed DLL to come from a worktree; it is not normal for nobody to know which.

If the fault budget is at or near 8, the inspector is dead or nearly dead for
that client session — restart before doing UI work rather than spending the
remainder guessing.
