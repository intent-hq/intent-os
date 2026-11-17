# Agent Workflow Guide

This repo is the `packages/intent-os` submodule of
[intent-hq/intent](https://github.com/intent-hq/intent). Read that repo's `AGENTS.md`
for commit, PR, and merge rules. They apply here.

## Rules

1. Do all Intent OS work in this repo.
2. Consume Intent as released. Install the published Linux build from
   [intent-hq/cloudlands-releases](https://github.com/intent-hq/cloudlands-releases);
   do not fork or patch `cloudlands-fe` or `intentd` here.
3. When the app must change (for example an OS-mode hook), make a small, gated change in
   the component repo and link it from the PR here. Keep such changes rare.
4. Keep the base thin. Add a package only when boot, hardware, the session, updates, or
   recovery need it. Record why in the PKGBUILD or the design doc.
5. Every change to the boot, session, or update path must pass the QEMU boot-to-Intent
   smoke test before merge.
