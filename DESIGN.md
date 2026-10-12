# dream.scene design cut

## Purpose

`dream.scene` is a renderer-agnostic world/scene presentation layer. It owns scene identity, transform inheritance, hierarchical bounds, masks, view-distance policy, and spatial traversal. It deliberately does **not** own gameplay entities, physics, meshes, materials, draw calls, renderer state, animation, or asset formats.

The intended boundary is:

```
game simulation / ECS / bespoke world state
                 |
                 | presentation binding
                 v
             dream.scene
                 |
                 | visible/query result handles
                 v
        renderer / audio / effects JPKs
```

A game entity may map to zero, one, or many scene nodes. A scene node need not map to a game entity.

## What was taken from OpenSceneGraph 3.6

The supplied OSG 3.6 source was treated as an architectural quarry, not a line-for-line port.

Useful concepts retained:

- `osg::Node` / `osg::Group`: hierarchical scene composition.
- `NodeVisitor`: distinct traversal intent and mask-gated subtree traversal.
- `Transform`: explicit parent-relative transforms and derived world transforms.
- node masks / `Switch`: cheap subtree participation gates.
- `LOD`: view-dependent child participation without mutating gameplay state.
- `PagedLOD`: the architectural idea that residency and representation may depend on traversal/view state.
- hierarchical bounds: prune whole subtrees before touching leaves.

Concepts deliberately rejected from the core:

- `StateSet` and inherited renderer/OpenGL state.
- Drawable/Geode ownership as the scene's primary identity model.
- C++ reference-counted object-per-node layout.
- callback-heavy visitor class taxonomy.
- renderer-specific cull/render stages.
- multi-parent transform DAG semantics in v0.1.

## Why transforms are a tree

OSG permits graph sharing, but transform sharing makes a node's world transform path-dependent. For Jess, shared meshes/materials/resources can be represented by shared resource handles without making transform identity multi-parent.

A tree gives:

- one world transform per node;
- O(1) parent lookup and sibling unlink/link;
- cheap cycle detection;
- simple dirty-subtree propagation;
- deterministic bounds ancestry;
- a clean numeric-handle representation.

If a real consumer eventually needs path-dependent transform instances, that can be added as an explicit instancing layer instead of imposing DAG costs on every node.

## Storage

There is one Lua `Scene` object. Nodes are generation-checked numeric handles backed by packed Luau buffers.

Current capacity cost: **200 bytes per node slot**:

- 32 B metadata / hierarchy / generation / masks / dirty flags / depth;
- 40 B local TRS;
- 48 B world affine 3x4 matrix;
- 24 B local AABB;
- 24 B own world AABB;
- 24 B aggregate subtree AABB;
- 8 B squared view-distance range.

Scratch traversal/dirty tables are retained and reused.

## Update model

The first implementation rebuilt every transform/bound every `update()`. Profiling showed this made an idle 100k-node scene cost ~17.39 ms.

The current implementation records dirty transform roots and dirty bounds ancestors:

1. direct transform edits are collapsed to the highest dirty roots;
2. only those subtrees recompute world transforms and own world bounds;
3. changed subtrees aggregate bounds bottom-up;
4. affected ancestors re-aggregate child bounds deepest-first;
5. an idle update returns immediately.

For streaming/import bursts, `beginBatch()` / `endBatch()` skips incremental ancestor bookkeeping and performs one full realization on the next `update()`.

## Spatial model

The scene hierarchy is also the first spatial hierarchy: subtree AABBs allow `queryAabb()` to reject whole branches. This is intentionally enough for cell/room/chunk-shaped worlds and mirrors the useful part of OSG's hierarchical culling model.

It is **not** yet a general dynamic BVH/octree. If consumers produce large flat scenes with poor spatial parentage, a separate spatial-policy JPK should be layered above/beside this core rather than contaminating node identity with one mandatory index.

## Likely next layers

- frustum-plane collection using the existing subtree AABBs;
- explicit residency/page policy modeled after the useful idea behind `PagedLOD`;
- optional grid/BVH spatial-policy JPK for flat/dynamic populations;
- presentation bindings for NIF/OpenMW and PSX room/zone importers;
- renderer submission JPK consuming scene handles, but no renderer state inside `dream.scene`.
