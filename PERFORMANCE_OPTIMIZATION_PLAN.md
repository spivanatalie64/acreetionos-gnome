# Performance Optimization Plan

This document is the repository-side source of truth for the current AcreetionOS build-performance work.

## Repository Overview

- Darren working repository: `gitlab.acreetionos.org/cobra3282000/acreetionos`
- Natalie working repository: `gitlab.acreetionos.org/natalie/acreetionos`
- Shared mirror target: `github.com/acreetionos-code/acreetionos`
- Darren intake branch: `darren-changes`

Workflow:

1. Darren pushes changes to `gitlab.acreetionos.org/cobra3282000/acreetionos`.
2. Darren may continue mirroring those changes to `github.com/acreetionos-code/acreetionos`.
3. Pull Darren's incoming changes into the local branch `darren-changes` for review and integration.
4. Perform active development and corrective work in `gitlab.acreetionos.org/natalie/acreetionos`.
5. Merge or cherry-pick validated Darren changes from `darren-changes` as needed.
6. Publish completed development work through the normal repository flow without blocking Darren's mirror activity.

Operational rule:

- Darren's mirror path remains intact.
- Natalie uses `darren-changes` as the intake branch for Darren-originated updates.
- Feature work and remediation proceed independently in Natalie-owned branches before integration.

## GitHub Tracking

- Milestone: `Performance Optimization Q2 2026`
- Labels: `enhancement`, `performance`
- Assignee: Natalie Spiva

## Issue And Branch Map

| Issue | Title | Branch | Type |
| --- | --- | --- | --- |
| `#2` | Implement Parallel Build Optimization | `feature/parallel-build` | Performance Optimization |
| `#3` | Optimize Compression Settings | `feature/smart-compression` | Performance Optimization |
| `#4` | Enable Package Parallel Downloads | `feature/package-tuning` | Performance Optimization |
| `#5` | Implement Build Performance Metrics | `feature/build-metrics` | Monitoring/Telemetry |
| `#6` | Research AI Agent Integration | `feature/aiden-integration` | AI Integration |

## Execution Order

1. `feature/build-metrics`
2. `feature/parallel-build`
3. `feature/smart-compression`
4. `feature/package-tuning`
5. `feature/aiden-integration`

The metrics branch comes first so that every later change can be measured against a stable baseline.

## Delivery Goals

- Reduce total ISO build time by 15-25%.
- Keep ISO size growth under 3% unless a measured tradeoff is approved.
- Preserve bootability and installer functionality.
- Keep changes incremental and reversible.

## Work Breakdown

### 1. Build Metrics

Branch: `feature/build-metrics`
Issue: `#5`

How this work will be done:

1. Add lightweight timing around the existing build entrypoints.
2. Capture wall-clock duration for `refresh.sh`, package staging, and `mkarchiso`.
3. Write a simple text or markdown summary artifact after each build.
4. Keep the instrumentation shell-native and low overhead.
5. Use the same benchmark path before and after every optimization branch.

Expected output:

- Repeatable baseline timings.
- A simple comparison report for future branches.

### 2. Parallel Build Optimization

Branch: `feature/parallel-build`
Issue: `#2`

How this work will be done:

1. Audit the current `build.sh`, `refresh.sh`, and `mkarchiso.sh` flow.
2. Correct current shell issues first if they prevent reliable parallel execution.
3. Replace unsafe or ineffective job flags with deterministic CPU detection.
4. Parallelize only independent work, keeping the overall build order intact.
5. Benchmark several thread counts instead of assuming `all cores` is always fastest.

Expected output:

- Faster builds with no change to final ISO behavior.
- A clearer and more reliable build wrapper.

### 3. Compression Optimization

Branch: `feature/smart-compression`
Issue: `#3`

How this work will be done:

1. Benchmark the current `squashfs` and bootstrap compression settings.
2. Test a small matrix of `xz` and `zstd` thread and level combinations.
3. Compare build time, output size, and boot/install behavior.
4. Keep the current filesystem format unless a measured change is clearly better.
5. Land the smallest config change that produces a repeatable improvement.

Expected output:

- Better compression throughput or better size/time balance.
- Documented rationale for the chosen settings.

### 4. Package Parallel Downloads

Branch: `feature/package-tuning`
Issue: `#4`

How this work will be done:

1. Review `pacman.conf` and current package acquisition behavior.
2. Enable `ParallelDownloads` with a conservative default.
3. Verify package list resolution still behaves correctly in the archiso environment.
4. Measure the impact on network-bound stages of the build.
5. Keep the change isolated to package retrieval behavior.

Expected output:

- Faster package download stages.
- No dependency-resolution regressions.

### 5. Aiden AI Agent Integration

Branch: `feature/aiden-integration`
Issue: `#6`

How this work will be done:

1. Confirm packaging and runtime requirements for Aiden.
2. Decide whether Aiden belongs in the ISO by default or as an optional package path.
3. Document the GitLab and `glab` workflow expected by the agent.
4. Add it only after build-performance work is measured so its impact is visible.
5. Treat this as optional until packaging, licensing, and UX are clear.

Expected output:

- A documented integration path.
- A package inclusion decision backed by measured impact.

## Validation Standard

Every branch should be validated with the same checklist:

1. Build completes successfully.
2. ISO artifact is produced in the expected location.
3. ISO boots in a VM.
4. Calamares still launches.
5. Measured results are recorded against the baseline.

## Cross-Machine Retrieval

After cloning on another machine, use either the file directly from the GitLab working repository or the GitHub milestone.

```bash
gh issue list --milestone "Performance Optimization Q2 2026" --state all
```

This file should remain updated as issue scope, branch names, or execution order changes.
