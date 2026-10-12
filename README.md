# dream.scene

Renderer-agnostic 3D scene/world presentation for Jess, implemented as a Luau JPK.

`require('@dream/scene')`

It owns packed scene identity, transform inheritance, hierarchical bounds, masks, view ranges, and spatial traversal. It owns **no renderer state, meshes, materials, physics, gameplay entities, or asset formats**.

## Core API

```lua
local Scene = require('@dream/scene')
local scene = Scene.new(100000)

scene:beginBatch()
local city = scene:create()
local npc = scene:create(city)
scene:setPosition(city, 1000, 2000, 0)
scene:setPosition(npc, 10, 20, 0)
scene:setBounds(npc, -0.5, -0.5, 0, 0.5, 0.5, 2)
scene:endBatch()
scene:update()

local nearby = scene:queryAabb(900, 1900, -100, 1100, 2100, 100)
local presentation = scene:collectForView(cameraX, cameraY, cameraZ)
```

Important operations:

- `new(initialCapacity?)`
- `create(parentHandle?) -> handle`
- `destroy(handle) -> removedCount`
- `setParent(handle, parentHandle?)`
- `setTransform`, `setPosition`, `setRotation`, `setScale`
- `setBounds`, `clearBounds`
- `setMask`, `setEnabled`
- `setRange(minDistance, maxDistance)`
- `update()`
- `collect(mask?, out?)`
- `queryAabb(..., mask?, out?)`
- `collectForView(x, y, z, mask?, out?)`
- `beginBatch()` / `endBatch()`
- `stats()`

Node handles are numeric and generation checked. Node objects are never allocated.

See `DESIGN.md` for the OSG-derived architecture cut and `PROFILE.md` plus `bench/results/` for measurements and raw Jess profiler output.
