# Profiling report

All measurements were produced by the supplied Jess binary on this execution environment. Timings are workload medians where the benchmark says so; treat them as comparative engineering data, not portable hardware promises.

Raw data is under `bench/results/` and the profiler scripts are under `bench/`. The benchmark that printed those tables has since been replaced by one that checks every answer it times; its numbers, on l3i 2.0, are in `BENCHMARKS.md`, and nothing below has been remeasured.

## Packed memory

The packed buffers reserve 200 bytes per capacity slot.

| Capacity | Packed storage |
|---:|---:|
| 1,000 | 0.191 MiB |
| 10,000 | 1.908 MiB |
| 100,000 | 19.074 MiB |
| 250,000 | 47.684 MiB |
| 1,000,000 | 190.735 MiB |

## Final benchmark

Synthetic shape: approximately one group/root per 64 nodes, bounded leaves, deterministic positions, one quarter of leaves carrying a finite view range.

| Nodes | Batch build + initial update | Idle update | Dirty leaf | Dirty ~64-node root | Dirty 1% leaves | Collect all | Tiny AABB query | Whole-world query | View collect |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1k | 0.786 ms | 0.00016 ms | 0.00226 ms | 0.0104 ms | 0.0148 ms | 0.0416 ms | 0.00060 ms | 0.0550 ms | 0.0634 ms |
| 10k | 8.44 ms | 0.00020 ms | 0.00678 ms | 0.0148 ms | 0.143 ms | 0.428 ms | 0.00874 ms | 0.592 ms | 0.567 ms |
| 100k | 100.85 ms | 0.00041 ms | 0.126 ms | 0.0844 ms | 4.10 ms | 6.85 ms | 0.0910 ms | 9.05 ms | 8.18 ms |
| 250k | 281.30 ms | 0.00050 ms | 0.194 ms | 0.189 ms | 11.97 ms | 17.27 ms | 0.416 ms | 27.39 ms | 25.14 ms |

At 1,000,000 nodes, one batch build + initial realization measured ~1.407 s; a tiny AABB query measured ~0.699 ms; intentionally collecting every handle measured ~147.77 ms.

## Optimization receipt

The original implementation rebuilt all bounds every update.

At 100k nodes:

| Work | Before | Final | Change |
|---|---:|---:|---:|
| Idle update | 17.391 ms | 0.000406 ms | ~42,834x lower |
| Dirty ~64-node root | 16.061 ms | 0.0844 ms | ~190x lower |
| Batch build + realization | 111.894 ms original build | 100.855 ms final batch build | ~1.11x faster |
| Collect all | 7.174 ms | 6.847 ms | ~1.05x faster |
| Tiny AABB query | 0.152 ms | 0.0910 ms | ~1.67x faster |
| Whole-world AABB query | 10.442 ms | 9.045 ms | ~1.15x faster |
| View collect | 8.719 ms | 8.182 ms | ~1.07x faster |

The important result is structural: cold frames are effectively free and localized mutations scale with the affected subtree/ancestors rather than total scene population.

## Jess `--profile` findings

Raw sampling/native-block reports are preserved in `bench/results/profiler-*.txt`.

Before the incremental rewrite, idle and dirty-root profiles were dominated by:

- copying every own-world AABB into subtree storage;
- walking every child edge for bottom-up subtree aggregation;
- scanning all 100k nodes even when nothing changed.

After the rewrite, the persistent hotspots are expected work:

- `_recomputeSubtreeBounds`: child-bound reduction, especially when many independently dirty leaves force parent re-aggregation;
- broad `collect` / whole-world `queryAabb`: stack traversal plus generation-safe handle emission;
- `collectForView`: subtree distance test plus handle emission;
- dirty-1%-of-world workloads: sorting/reducing affected bounds ancestors and child-bound reduction.

The final profiler runs execute overwhelmingly as native blocks with only three VM exits in each captured workload.

## Candidate native/lowered primitives if Luau stops being enough

The profile does **not** justify moving the scene graph into Jess/Rust. It does identify narrow candidates that could become reusable L3i primitives if future consumers prove the need:

1. affine parent*local 3x4 transform composition over packed buffers;
2. transformed-AABB calculation from affine matrix + local AABB;
3. reduction of N child AABBs into one parent AABB;
4. masked packed-tree traversal with handle emission;
5. batched frustum/AABB tests over packed bounds.

Those are math/data-motion primitives, not a privileged `SceneNode` engine API.

## Known stress result

A churn workload that creates and immediately destroys 1,000 leaves across many parents, then repairs parent bounds, measured ~74.8 ms at a 100k-node scene. That is intentionally visible rather than hidden: highly ephemeral populations should generally live in a specialized instance/particle structure instead of forcing the persistent scene hierarchy to behave like a particle allocator.
