--!strict
--!native

-- Renderer-agnostic scene/world presentation storage.
-- Nodes are integer handles into packed buffers; there is one Lua object per Scene, not per node.
-- Transform ownership is intentionally a tree. Resources referenced by consumers can still be shared.

local Scene = {}
Scene.__index = Scene

local HANDLE_STRIDE = 16777216 -- 2^24: 24 bits of slot, remaining exact integer bits for generation.
local MAX_SLOT = HANDLE_STRIDE - 1

local META_STRIDE = 32
local M_PARENT = 0
local M_FIRST_CHILD = 4
local M_NEXT = 8
local M_PREV = 12
local M_GENERATION = 16
local M_MASK = 20
local M_FLAGS = 24
local M_DEPTH = 28

local F_ALIVE = 1
local F_XFORM_DIRTY = 2
local F_OWN_BOUNDS = 4
local F_ENABLED = 8
local F_BOUNDS_DIRTY = 16
local F_OWN_BOUNDS_DIRTY = 32

local LOCAL_STRIDE = 40 -- xyz + quaternion xyzw + scale xyz
local L_PX = 0
local L_PY = 4
local L_PZ = 8
local L_QX = 12
local L_QY = 16
local L_QZ = 20
local L_QW = 24
local L_SX = 28
local L_SY = 32
local L_SZ = 36

local MAT_STRIDE = 48 -- 3x4 row-major affine matrix
local BOUNDS_STRIDE = 24 -- min xyz, max xyz
local RANGE_STRIDE = 8 -- squared min/max view distance
local INF = math.huge

local function encode(slot: number, generation: number): number
    return generation * HANDLE_STRIDE + slot
end

local function decode(handle: number): (number, number)
    local generation = math.floor(handle / HANDLE_STRIDE)
    local slot = handle - generation * HANDLE_STRIDE
    return slot, generation
end

local function growBuffer(old: buffer, bytes: number): buffer
    local nextBuffer = buffer.create(bytes)
    buffer.copy(nextBuffer, 0, old, 0, buffer.len(old))
    return nextBuffer
end

local function overlapsAabb(
    aminx: number, aminy: number, aminz: number, amaxx: number, amaxy: number, amaxz: number,
    bminx: number, bminy: number, bminz: number, bmaxx: number, bmaxy: number, bmaxz: number
): boolean
    return aminx <= bmaxx and amaxx >= bminx
        and aminy <= bmaxy and amaxy >= bminy
        and aminz <= bmaxz and amaxz >= bminz
end

local function pointAabbDistanceSq(
    x: number, y: number, z: number,
    minx: number, miny: number, minz: number, maxx: number, maxy: number, maxz: number
): number
    local dx = 0.0
    local dy = 0.0
    local dz = 0.0
    if x < minx then dx = minx - x elseif x > maxx then dx = x - maxx end
    if y < miny then dy = miny - y elseif y > maxy then dy = y - maxy end
    if z < minz then dz = minz - z elseif z > maxz then dz = z - maxz end
    return dx * dx + dy * dy + dz * dz
end

function Scene.new(initialCapacity: number?): any
    local capacity = math.max(16, math.floor(initialCapacity or 256))
    assert(capacity <= MAX_SLOT, "scene: initial capacity exceeds handle slot space")

    local self = setmetatable({
        _capacity = capacity,
        _count = 0,
        _high = 0,
        _free = 0,
        _firstRoot = 0,
        _roots = 0,
        _version = 0,
        _batchDepth = 0,
        _fullDirty = false,

        _meta = buffer.create((capacity + 1) * META_STRIDE),
        _local = buffer.create((capacity + 1) * LOCAL_STRIDE),
        _world = buffer.create((capacity + 1) * MAT_STRIDE),
        _localBounds = buffer.create((capacity + 1) * BOUNDS_STRIDE),
        _ownWorldBounds = buffer.create((capacity + 1) * BOUNDS_STRIDE),
        _subtreeBounds = buffer.create((capacity + 1) * BOUNDS_STRIDE),
        _range = buffer.create((capacity + 1) * RANGE_STRIDE),

        -- Reused scratch. No per-frame node tables are allocated by update/query paths.
        _stack = table.create(256),
        _order = table.create(256),
        _dirtyTransforms = table.create(256),
        _dirtyBounds = table.create(256),
        _transformRoots = table.create(64),
        _remainingBounds = table.create(64),
    }, Scene)

    return self
end

function Scene:_ensure(slot: number)
    if slot <= self._capacity then return end
    local capacity = self._capacity
    repeat
        capacity *= 2
        assert(capacity <= MAX_SLOT, "scene: node capacity exhausted")
    until capacity >= slot

    self._meta = growBuffer(self._meta, (capacity + 1) * META_STRIDE)
    self._local = growBuffer(self._local, (capacity + 1) * LOCAL_STRIDE)
    self._world = growBuffer(self._world, (capacity + 1) * MAT_STRIDE)
    self._localBounds = growBuffer(self._localBounds, (capacity + 1) * BOUNDS_STRIDE)
    self._ownWorldBounds = growBuffer(self._ownWorldBounds, (capacity + 1) * BOUNDS_STRIDE)
    self._subtreeBounds = growBuffer(self._subtreeBounds, (capacity + 1) * BOUNDS_STRIDE)
    self._range = growBuffer(self._range, (capacity + 1) * RANGE_STRIDE)
    self._capacity = capacity
end

function Scene:_slot(handle: number): number
    local slot, generation = decode(handle)
    if slot <= 0 or slot > self._high then
        error("scene: invalid node handle", 3)
    end
    local mo = slot * META_STRIDE
    local flags = buffer.readu32(self._meta, mo + M_FLAGS)
    if bit32.band(flags, F_ALIVE) == 0 or buffer.readu32(self._meta, mo + M_GENERATION) ~= generation then
        error("scene: stale node handle", 3)
    end
    return slot
end

function Scene:isAlive(handle: number): boolean
    local slot, generation = decode(handle)
    if slot <= 0 or slot > self._high then return false end
    local mo = slot * META_STRIDE
    return bit32.band(buffer.readu32(self._meta, mo + M_FLAGS), F_ALIVE) ~= 0
        and buffer.readu32(self._meta, mo + M_GENERATION) == generation
end

function Scene:_handle(slot: number): number
    return encode(slot, buffer.readu32(self._meta, slot * META_STRIDE + M_GENERATION))
end

function Scene:_queueBounds(slot: number)
    if self._batchDepth > 0 then self._fullDirty = true; return end
    while slot ~= 0 do
        local mo = slot * META_STRIDE
        local flags = buffer.readu32(self._meta, mo + M_FLAGS)
        if bit32.band(flags, F_BOUNDS_DIRTY) == 0 then
            buffer.writeu32(self._meta, mo + M_FLAGS, bit32.bor(flags, F_BOUNDS_DIRTY))
            local list = self._dirtyBounds
            list[#list + 1] = slot
        end
        slot = buffer.readi32(self._meta, mo + M_PARENT)
    end
end

function Scene:_markTransform(slot: number)
    local mo = slot * META_STRIDE
    local flags = buffer.readu32(self._meta, mo + M_FLAGS)
    if bit32.band(flags, F_XFORM_DIRTY) == 0 then
        buffer.writeu32(self._meta, mo + M_FLAGS, bit32.bor(flags, F_XFORM_DIRTY))
        if self._batchDepth == 0 then
            local list = self._dirtyTransforms
            list[#list + 1] = slot
        else
            self._fullDirty = true
        end
    elseif self._batchDepth > 0 then
        self._fullDirty = true
    end
    self:_queueBounds(slot)
end

function Scene:_markOwnBounds(slot: number)
    local mo = slot * META_STRIDE
    local flags = buffer.readu32(self._meta, mo + M_FLAGS)
    buffer.writeu32(self._meta, mo + M_FLAGS, bit32.bor(flags, F_OWN_BOUNDS_DIRTY))
    self:_queueBounds(slot)
end

function Scene:_updateOwnWorldBounds(slot: number)
    local bo = slot * BOUNDS_STRIDE
    local minx,miny,minz = buffer.readf32(self._localBounds,bo),buffer.readf32(self._localBounds,bo+4),buffer.readf32(self._localBounds,bo+8)
    local maxx,maxy,maxz = buffer.readf32(self._localBounds,bo+12),buffer.readf32(self._localBounds,bo+16),buffer.readf32(self._localBounds,bo+20)
    local cx,cy,cz = (minx+maxx)*0.5,(miny+maxy)*0.5,(minz+maxz)*0.5
    local ex,ey,ez = (maxx-minx)*0.5,(maxy-miny)*0.5,(maxz-minz)*0.5
    local wo = slot * MAT_STRIDE
    local m00,m01,m02,tx = buffer.readf32(self._world,wo),buffer.readf32(self._world,wo+4),buffer.readf32(self._world,wo+8),buffer.readf32(self._world,wo+12)
    local m10,m11,m12,ty = buffer.readf32(self._world,wo+16),buffer.readf32(self._world,wo+20),buffer.readf32(self._world,wo+24),buffer.readf32(self._world,wo+28)
    local m20,m21,m22,tz = buffer.readf32(self._world,wo+32),buffer.readf32(self._world,wo+36),buffer.readf32(self._world,wo+40),buffer.readf32(self._world,wo+44)
    local wcx,wcy,wcz = m00*cx+m01*cy+m02*cz+tx, m10*cx+m11*cy+m12*cz+ty, m20*cx+m21*cy+m22*cz+tz
    local wex = math.abs(m00)*ex+math.abs(m01)*ey+math.abs(m02)*ez
    local wey = math.abs(m10)*ex+math.abs(m11)*ey+math.abs(m12)*ez
    local wez = math.abs(m20)*ex+math.abs(m21)*ey+math.abs(m22)*ez
    buffer.writef32(self._ownWorldBounds,bo,wcx-wex); buffer.writef32(self._ownWorldBounds,bo+4,wcy-wey); buffer.writef32(self._ownWorldBounds,bo+8,wcz-wez)
    buffer.writef32(self._ownWorldBounds,bo+12,wcx+wex); buffer.writef32(self._ownWorldBounds,bo+16,wcy+wey); buffer.writef32(self._ownWorldBounds,bo+20,wcz+wez)
end

function Scene:_recomputeSubtreeBounds(slot: number)
    local mo = slot * META_STRIDE
    local flags = buffer.readu32(self._meta, mo + M_FLAGS)
    local bo = slot * BOUNDS_STRIDE
    local minx,miny,minz,maxx,maxy,maxz
    if bit32.band(flags, F_OWN_BOUNDS) ~= 0 then
        minx,miny,minz = buffer.readf32(self._ownWorldBounds,bo),buffer.readf32(self._ownWorldBounds,bo+4),buffer.readf32(self._ownWorldBounds,bo+8)
        maxx,maxy,maxz = buffer.readf32(self._ownWorldBounds,bo+12),buffer.readf32(self._ownWorldBounds,bo+16),buffer.readf32(self._ownWorldBounds,bo+20)
    else
        minx,miny,minz,maxx,maxy,maxz = INF,INF,INF,-INF,-INF,-INF
    end
    local child = buffer.readi32(self._meta, mo + M_FIRST_CHILD)
    while child ~= 0 do
        local cbo = child * BOUNDS_STRIDE
        local cminx,cminy,cminz = buffer.readf32(self._subtreeBounds,cbo),buffer.readf32(self._subtreeBounds,cbo+4),buffer.readf32(self._subtreeBounds,cbo+8)
        local cmaxx,cmaxy,cmaxz = buffer.readf32(self._subtreeBounds,cbo+12),buffer.readf32(self._subtreeBounds,cbo+16),buffer.readf32(self._subtreeBounds,cbo+20)
        if cminx <= cmaxx then
            minx,miny,minz = math.min(minx,cminx),math.min(miny,cminy),math.min(minz,cminz)
            maxx,maxy,maxz = math.max(maxx,cmaxx),math.max(maxy,cmaxy),math.max(maxz,cmaxz)
        end
        child = buffer.readi32(self._meta, child * META_STRIDE + M_NEXT)
    end
    buffer.writef32(self._subtreeBounds,bo,minx); buffer.writef32(self._subtreeBounds,bo+4,miny); buffer.writef32(self._subtreeBounds,bo+8,minz)
    buffer.writef32(self._subtreeBounds,bo+12,maxx); buffer.writef32(self._subtreeBounds,bo+16,maxy); buffer.writef32(self._subtreeBounds,bo+20,maxz)
end

function Scene:_unlink(slot: number)
    local mo = slot * META_STRIDE
    local parent = buffer.readi32(self._meta, mo + M_PARENT)
    local prev = buffer.readi32(self._meta, mo + M_PREV)
    local nextNode = buffer.readi32(self._meta, mo + M_NEXT)

    if prev ~= 0 then
        buffer.writei32(self._meta, prev * META_STRIDE + M_NEXT, nextNode)
    elseif parent ~= 0 then
        buffer.writei32(self._meta, parent * META_STRIDE + M_FIRST_CHILD, nextNode)
    else
        self._firstRoot = nextNode
        self._roots -= 1
    end
    if nextNode ~= 0 then
        buffer.writei32(self._meta, nextNode * META_STRIDE + M_PREV, prev)
    end

    buffer.writei32(self._meta, mo + M_PARENT, 0)
    buffer.writei32(self._meta, mo + M_PREV, 0)
    buffer.writei32(self._meta, mo + M_NEXT, 0)
end

function Scene:_link(slot: number, parent: number)
    local mo = slot * META_STRIDE
    buffer.writei32(self._meta, mo + M_PARENT, parent)
    local depth = 0
    if parent ~= 0 then depth = buffer.readu32(self._meta, parent * META_STRIDE + M_DEPTH) + 1 end
    buffer.writeu32(self._meta, mo + M_DEPTH, depth)
    buffer.writei32(self._meta, mo + M_PREV, 0)
    if parent ~= 0 then
        local po = parent * META_STRIDE
        local first = buffer.readi32(self._meta, po + M_FIRST_CHILD)
        buffer.writei32(self._meta, mo + M_NEXT, first)
        if first ~= 0 then buffer.writei32(self._meta, first * META_STRIDE + M_PREV, slot) end
        buffer.writei32(self._meta, po + M_FIRST_CHILD, slot)
    else
        local first = self._firstRoot
        buffer.writei32(self._meta, mo + M_NEXT, first)
        if first ~= 0 then buffer.writei32(self._meta, first * META_STRIDE + M_PREV, slot) end
        self._firstRoot = slot
        self._roots += 1
    end
end

function Scene:create(parentHandle: number?): number
    local slot
    if self._free ~= 0 then
        slot = self._free
        local mo = slot * META_STRIDE
        self._free = buffer.readi32(self._meta, mo + M_NEXT)
    else
        slot = self._high + 1
        self:_ensure(slot)
        self._high = slot
        buffer.writeu32(self._meta, slot * META_STRIDE + M_GENERATION, 1)
    end

    local mo = slot * META_STRIDE
    local generation = buffer.readu32(self._meta, mo + M_GENERATION)
    if generation == 0 then
        generation = 1
        buffer.writeu32(self._meta, mo + M_GENERATION, generation)
    end
    buffer.writei32(self._meta, mo + M_FIRST_CHILD, 0)
    buffer.writeu32(self._meta, mo + M_MASK, 0xffffffff)
    if self._batchDepth > 0 then
        buffer.writeu32(self._meta, mo + M_FLAGS, bit32.bor(F_ALIVE, F_XFORM_DIRTY, F_ENABLED))
        self._fullDirty = true
    else
        buffer.writeu32(self._meta, mo + M_FLAGS, bit32.bor(F_ALIVE, F_XFORM_DIRTY, F_ENABLED, F_BOUNDS_DIRTY))
        self._dirtyTransforms[#self._dirtyTransforms + 1] = slot
        self._dirtyBounds[#self._dirtyBounds + 1] = slot
    end

    local lo = slot * LOCAL_STRIDE
    buffer.writef32(self._local, lo + L_PX, 0)
    buffer.writef32(self._local, lo + L_PY, 0)
    buffer.writef32(self._local, lo + L_PZ, 0)
    buffer.writef32(self._local, lo + L_QX, 0)
    buffer.writef32(self._local, lo + L_QY, 0)
    buffer.writef32(self._local, lo + L_QZ, 0)
    buffer.writef32(self._local, lo + L_QW, 1)
    buffer.writef32(self._local, lo + L_SX, 1)
    buffer.writef32(self._local, lo + L_SY, 1)
    buffer.writef32(self._local, lo + L_SZ, 1)

    local ro = slot * RANGE_STRIDE
    buffer.writef32(self._range, ro, 0)
    buffer.writef32(self._range, ro + 4, INF)

    self:_link(slot, 0)
    self._count += 1
    local handle = encode(slot, generation)
    if parentHandle ~= nil then self:setParent(handle, parentHandle) end
    return handle
end

function Scene:destroy(handle: number): number
    local root = self:_slot(handle)
    local oldParent = buffer.readi32(self._meta, root * META_STRIDE + M_PARENT)
    self:_unlink(root)
    if oldParent ~= 0 then self:_queueBounds(oldParent) end

    local stack = self._stack
    local order = self._order
    table.clear(stack)
    table.clear(order)
    local top = 1
    stack[1] = root
    local n = 0

    while top > 0 do
        local slot = stack[top]
        stack[top] = nil
        top -= 1
        n += 1
        order[n] = slot
        local child = buffer.readi32(self._meta, slot * META_STRIDE + M_FIRST_CHILD)
        while child ~= 0 do
            top += 1
            stack[top] = child
            child = buffer.readi32(self._meta, child * META_STRIDE + M_NEXT)
        end
    end

    for i = 1, n do
        local slot = order[i]
        local mo = slot * META_STRIDE
        local generation = buffer.readu32(self._meta, mo + M_GENERATION) + 1
        if generation >= 0x1fffffff then generation = 1 end
        buffer.writeu32(self._meta, mo + M_GENERATION, generation)
        buffer.writeu32(self._meta, mo + M_FLAGS, 0)
        buffer.writei32(self._meta, mo + M_PARENT, 0)
        buffer.writei32(self._meta, mo + M_FIRST_CHILD, 0)
        buffer.writei32(self._meta, mo + M_PREV, 0)
        buffer.writei32(self._meta, mo + M_NEXT, self._free)
        self._free = slot
    end
    self._count -= n
    return n
end

function Scene:setParent(handle: number, parentHandle: number?)
    local slot = self:_slot(handle)
    local parent = 0
    if parentHandle ~= nil then
        parent = self:_slot(parentHandle)
        assert(parent ~= slot, "scene: node cannot parent itself")
        local p = parent
        while p ~= 0 do
            assert(p ~= slot, "scene: parenting would create a cycle")
            p = buffer.readi32(self._meta, p * META_STRIDE + M_PARENT)
        end
    end

    local current = buffer.readi32(self._meta, slot * META_STRIDE + M_PARENT)
    if current == parent then return end
    self:_unlink(slot)
    if current ~= 0 then self:_queueBounds(current) end
    self:_link(slot, parent)
    self:_markTransform(slot)
end

function Scene:parent(handle: number): number?
    local slot = self:_slot(handle)
    local parent = buffer.readi32(self._meta, slot * META_STRIDE + M_PARENT)
    if parent == 0 then return nil end
    return self:_handle(parent)
end

function Scene:setTransform(
    handle: number,
    px: number, py: number, pz: number,
    qx: number, qy: number, qz: number, qw: number,
    sx: number, sy: number, sz: number
)
    local slot = self:_slot(handle)
    local lo = slot * LOCAL_STRIDE
    buffer.writef32(self._local, lo + L_PX, px)
    buffer.writef32(self._local, lo + L_PY, py)
    buffer.writef32(self._local, lo + L_PZ, pz)
    buffer.writef32(self._local, lo + L_QX, qx)
    buffer.writef32(self._local, lo + L_QY, qy)
    buffer.writef32(self._local, lo + L_QZ, qz)
    buffer.writef32(self._local, lo + L_QW, qw)
    buffer.writef32(self._local, lo + L_SX, sx)
    buffer.writef32(self._local, lo + L_SY, sy)
    buffer.writef32(self._local, lo + L_SZ, sz)
    self:_markTransform(slot)
end

function Scene:setPosition(handle: number, x: number, y: number, z: number)
    local slot = self:_slot(handle)
    local lo = slot * LOCAL_STRIDE
    buffer.writef32(self._local, lo + L_PX, x)
    buffer.writef32(self._local, lo + L_PY, y)
    buffer.writef32(self._local, lo + L_PZ, z)
    self:_markTransform(slot)
end

function Scene:setRotation(handle: number, x: number, y: number, z: number, w: number)
    local slot = self:_slot(handle)
    local lo = slot * LOCAL_STRIDE
    buffer.writef32(self._local, lo + L_QX, x)
    buffer.writef32(self._local, lo + L_QY, y)
    buffer.writef32(self._local, lo + L_QZ, z)
    buffer.writef32(self._local, lo + L_QW, w)
    self:_markTransform(slot)
end

function Scene:setScale(handle: number, x: number, y: number, z: number)
    local slot = self:_slot(handle)
    local lo = slot * LOCAL_STRIDE
    buffer.writef32(self._local, lo + L_SX, x)
    buffer.writef32(self._local, lo + L_SY, y)
    buffer.writef32(self._local, lo + L_SZ, z)
    self:_markTransform(slot)
end

function Scene:setBounds(handle: number, minx: number, miny: number, minz: number, maxx: number, maxy: number, maxz: number)
    assert(minx <= maxx and miny <= maxy and minz <= maxz, "scene: invalid bounds")
    local slot = self:_slot(handle)
    local bo = slot * BOUNDS_STRIDE
    buffer.writef32(self._localBounds, bo, minx)
    buffer.writef32(self._localBounds, bo + 4, miny)
    buffer.writef32(self._localBounds, bo + 8, minz)
    buffer.writef32(self._localBounds, bo + 12, maxx)
    buffer.writef32(self._localBounds, bo + 16, maxy)
    buffer.writef32(self._localBounds, bo + 20, maxz)
    local mo = slot * META_STRIDE
    buffer.writeu32(self._meta, mo + M_FLAGS, bit32.bor(buffer.readu32(self._meta, mo + M_FLAGS), F_OWN_BOUNDS))
    self:_markOwnBounds(slot)
end

function Scene:clearBounds(handle: number)
    local slot = self:_slot(handle)
    local mo = slot * META_STRIDE
    local flags = buffer.readu32(self._meta, mo + M_FLAGS)
    flags = bit32.band(flags, bit32.bnot(F_OWN_BOUNDS))
    buffer.writeu32(self._meta, mo + M_FLAGS, flags)
    self:_markOwnBounds(slot)
end

function Scene:setMask(handle: number, mask: number)
    local slot = self:_slot(handle)
    buffer.writeu32(self._meta, slot * META_STRIDE + M_MASK, mask)
end

function Scene:setEnabled(handle: number, enabled: boolean)
    local slot = self:_slot(handle)
    local mo = slot * META_STRIDE
    local flags = buffer.readu32(self._meta, mo + M_FLAGS)
    if enabled then flags = bit32.bor(flags, F_ENABLED) else flags = bit32.band(flags, bit32.bnot(F_ENABLED)) end
    buffer.writeu32(self._meta, mo + M_FLAGS, flags)
end

function Scene:setRange(handle: number, minDistance: number, maxDistance: number)
    assert(minDistance >= 0 and maxDistance >= minDistance, "scene: invalid LOD range")
    local slot = self:_slot(handle)
    local ro = slot * RANGE_STRIDE
    buffer.writef32(self._range, ro, minDistance * minDistance)
    buffer.writef32(self._range, ro + 4, maxDistance == INF and INF or maxDistance * maxDistance)
end

function Scene:getWorldPosition(handle: number): (number, number, number)
    local slot = self:_slot(handle)
    local wo = slot * MAT_STRIDE
    return buffer.readf32(self._world, wo + 12), buffer.readf32(self._world, wo + 28), buffer.readf32(self._world, wo + 44)
end

function Scene:beginBatch()
    self._batchDepth += 1
end

function Scene:endBatch()
    assert(self._batchDepth > 0, "scene: endBatch without beginBatch")
    self._batchDepth -= 1
end

function Scene:update(): { nodesVisited: number, transformsUpdated: number, boundedNodes: number, boundsUpdated: number }
    assert(self._batchDepth == 0, "scene: update during batch")
    local dirtyTransforms = self._dirtyTransforms
    local dirtyBounds = self._dirtyBounds
    if not self._fullDirty and #dirtyTransforms == 0 and #dirtyBounds == 0 then
        return { nodesVisited = 0, transformsUpdated = 0, boundedNodes = 0, boundsUpdated = 0 }
    end

    local transformRoots = self._transformRoots
    table.clear(transformRoots)
    if self._fullDirty then
        local root = self._firstRoot
        while root ~= 0 do
            transformRoots[#transformRoots + 1] = root
            root = buffer.readi32(self._meta, root * META_STRIDE + M_NEXT)
        end
    else
        -- Collapse direct transform dirties to the highest dirty roots before clearing any flags.
        for i = 1, #dirtyTransforms do
            local slot = dirtyTransforms[i]
            local mo = slot * META_STRIDE
            local flags = buffer.readu32(self._meta, mo + M_FLAGS)
            if bit32.band(flags, bit32.bor(F_ALIVE, F_XFORM_DIRTY)) == bit32.bor(F_ALIVE, F_XFORM_DIRTY) then
                local parent = buffer.readi32(self._meta, mo + M_PARENT)
                local covered = false
                while parent ~= 0 do
                    local pflags = buffer.readu32(self._meta, parent * META_STRIDE + M_FLAGS)
                    if bit32.band(pflags, F_XFORM_DIRTY) ~= 0 then covered = true; break end
                    parent = buffer.readi32(self._meta, parent * META_STRIDE + M_PARENT)
                end
                if not covered then transformRoots[#transformRoots + 1] = slot end
            end
        end
    end

    local stack = self._stack
    local order = self._order
    table.clear(stack)
    table.clear(order)
    for i = 1, #transformRoots do stack[i] = transformRoots[i] end
    local top = #transformRoots
    local n = 0
    local boundedNodes = 0

    -- Every descendant of a dirty transform root inherits a new world transform.
    while top > 0 do
        local slot = stack[top]; stack[top] = nil; top -= 1
        local mo = slot * META_STRIDE
        local flags = buffer.readu32(self._meta, mo + M_FLAGS)
        n += 1; order[n] = slot

        local parent = buffer.readi32(self._meta, mo + M_PARENT)
        local depth = 0
        if parent ~= 0 then depth = buffer.readu32(self._meta, parent * META_STRIDE + M_DEPTH) + 1 end
        buffer.writeu32(self._meta, mo + M_DEPTH, depth)

        local lo = slot * LOCAL_STRIDE
        local px = buffer.readf32(self._local, lo + L_PX)
        local py = buffer.readf32(self._local, lo + L_PY)
        local pz = buffer.readf32(self._local, lo + L_PZ)
        local qx = buffer.readf32(self._local, lo + L_QX)
        local qy = buffer.readf32(self._local, lo + L_QY)
        local qz = buffer.readf32(self._local, lo + L_QZ)
        local qw = buffer.readf32(self._local, lo + L_QW)
        local sx = buffer.readf32(self._local, lo + L_SX)
        local sy = buffer.readf32(self._local, lo + L_SY)
        local sz = buffer.readf32(self._local, lo + L_SZ)
        local xx,yy,zz = qx*qx,qy*qy,qz*qz
        local xy,xz,yz = qx*qy,qx*qz,qy*qz
        local xw,yw,zw = qx*qw,qy*qw,qz*qw
        local l00=(1-2*(yy+zz))*sx; local l01=(2*(xy-zw))*sy; local l02=(2*(xz+yw))*sz
        local l10=(2*(xy+zw))*sx; local l11=(1-2*(xx+zz))*sy; local l12=(2*(yz-xw))*sz
        local l20=(2*(xz-yw))*sx; local l21=(2*(yz+xw))*sy; local l22=(1-2*(xx+yy))*sz
        local wo = slot * MAT_STRIDE
        if parent == 0 then
            buffer.writef32(self._world,wo,l00); buffer.writef32(self._world,wo+4,l01); buffer.writef32(self._world,wo+8,l02); buffer.writef32(self._world,wo+12,px)
            buffer.writef32(self._world,wo+16,l10); buffer.writef32(self._world,wo+20,l11); buffer.writef32(self._world,wo+24,l12); buffer.writef32(self._world,wo+28,py)
            buffer.writef32(self._world,wo+32,l20); buffer.writef32(self._world,wo+36,l21); buffer.writef32(self._world,wo+40,l22); buffer.writef32(self._world,wo+44,pz)
        else
            local po=parent*MAT_STRIDE
            local p00,p01,p02,p03=buffer.readf32(self._world,po),buffer.readf32(self._world,po+4),buffer.readf32(self._world,po+8),buffer.readf32(self._world,po+12)
            local p10,p11,p12,p13=buffer.readf32(self._world,po+16),buffer.readf32(self._world,po+20),buffer.readf32(self._world,po+24),buffer.readf32(self._world,po+28)
            local p20,p21,p22,p23=buffer.readf32(self._world,po+32),buffer.readf32(self._world,po+36),buffer.readf32(self._world,po+40),buffer.readf32(self._world,po+44)
            buffer.writef32(self._world,wo,p00*l00+p01*l10+p02*l20); buffer.writef32(self._world,wo+4,p00*l01+p01*l11+p02*l21); buffer.writef32(self._world,wo+8,p00*l02+p01*l12+p02*l22); buffer.writef32(self._world,wo+12,p00*px+p01*py+p02*pz+p03)
            buffer.writef32(self._world,wo+16,p10*l00+p11*l10+p12*l20); buffer.writef32(self._world,wo+20,p10*l01+p11*l11+p12*l21); buffer.writef32(self._world,wo+24,p10*l02+p11*l12+p12*l22); buffer.writef32(self._world,wo+28,p10*px+p11*py+p12*pz+p13)
            buffer.writef32(self._world,wo+32,p20*l00+p21*l10+p22*l20); buffer.writef32(self._world,wo+36,p20*l01+p21*l11+p22*l21); buffer.writef32(self._world,wo+40,p20*l02+p21*l12+p22*l22); buffer.writef32(self._world,wo+44,p20*px+p21*py+p22*pz+p23)
        end
        if bit32.band(flags,F_OWN_BOUNDS) ~= 0 then self:_updateOwnWorldBounds(slot); boundedNodes += 1 end
        flags = bit32.band(flags, bit32.bnot(bit32.bor(F_XFORM_DIRTY, F_OWN_BOUNDS_DIRTY)))
        buffer.writeu32(self._meta, mo + M_FLAGS, flags)

        local child=buffer.readi32(self._meta,mo+M_FIRST_CHILD)
        while child ~= 0 do top+=1; stack[top]=child; child=buffer.readi32(self._meta,child*META_STRIDE+M_NEXT) end
    end

    -- Dirty transform subtrees are complete; fold their bounds bottom-up.
    local boundsUpdated = 0
    for i = n, 1, -1 do
        local slot = order[i]
        self:_recomputeSubtreeBounds(slot)
        boundsUpdated += 1
        local mo = slot * META_STRIDE
        local flags = buffer.readu32(self._meta, mo + M_FLAGS)
        buffer.writeu32(self._meta, mo + M_FLAGS, bit32.band(flags, bit32.bnot(F_BOUNDS_DIRTY)))
    end

    -- What remains are ancestors of changed subtrees or bounds-only edits. Depth order guarantees children first.
    local remaining = self._remainingBounds
    table.clear(remaining)
    for i = 1, #dirtyBounds do
        local slot = dirtyBounds[i]
        local flags = buffer.readu32(self._meta, slot * META_STRIDE + M_FLAGS)
        if bit32.band(flags, bit32.bor(F_ALIVE,F_BOUNDS_DIRTY)) == bit32.bor(F_ALIVE,F_BOUNDS_DIRTY) then
            remaining[#remaining + 1] = slot
        end
    end
    table.sort(remaining, function(a,b)
        return buffer.readu32(self._meta,a*META_STRIDE+M_DEPTH) > buffer.readu32(self._meta,b*META_STRIDE+M_DEPTH)
    end)
    for i = 1, #remaining do
        local slot = remaining[i]
        local mo = slot * META_STRIDE
        local flags = buffer.readu32(self._meta, mo + M_FLAGS)
        if bit32.band(flags,F_OWN_BOUNDS_DIRTY) ~= 0 then
            if bit32.band(flags,F_OWN_BOUNDS) ~= 0 then self:_updateOwnWorldBounds(slot); boundedNodes += 1 end
            flags = bit32.band(flags, bit32.bnot(F_OWN_BOUNDS_DIRTY))
        end
        self:_recomputeSubtreeBounds(slot)
        boundsUpdated += 1
        flags = bit32.band(flags, bit32.bnot(F_BOUNDS_DIRTY))
        buffer.writeu32(self._meta, mo + M_FLAGS, flags)
    end

    table.clear(dirtyTransforms)
    table.clear(dirtyBounds)
    self._fullDirty = false
    self._version += 1
    return { nodesVisited = n, transformsUpdated = n, boundedNodes = boundedNodes, boundsUpdated = boundsUpdated }
end

function Scene:collect(mask: number?, out: {number}?): {number}
    local traversalMask = mask or 0xffffffff
    local result = out or {}
    table.clear(result)
    local stack = self._stack
    table.clear(stack)
    local top = 0
    local root = self._firstRoot
    while root ~= 0 do top += 1; stack[top] = root; root = buffer.readi32(self._meta, root*META_STRIDE+M_NEXT) end
    local count = 0
    while top > 0 do
        local slot = stack[top]; stack[top] = nil; top -= 1
        local mo = slot * META_STRIDE
        local flags = buffer.readu32(self._meta,mo+M_FLAGS)
        if bit32.band(flags,F_ENABLED) ~= 0 and bit32.band(buffer.readu32(self._meta,mo+M_MASK),traversalMask) ~= 0 then
            count += 1; result[count] = self:_handle(slot)
            local child = buffer.readi32(self._meta,mo+M_FIRST_CHILD)
            while child ~= 0 do top += 1; stack[top] = child; child = buffer.readi32(self._meta,child*META_STRIDE+M_NEXT) end
        end
    end
    return result
end

function Scene:queryAabb(
    minx: number, miny: number, minz: number, maxx: number, maxy: number, maxz: number,
    mask: number?, out: {number}?
): {number}
    local traversalMask = mask or 0xffffffff
    local result = out or {}
    table.clear(result)
    local stack = self._stack
    table.clear(stack)
    local top = 0
    local root = self._firstRoot
    while root ~= 0 do top += 1; stack[top] = root; root = buffer.readi32(self._meta,root*META_STRIDE+M_NEXT) end
    local count = 0
    while top > 0 do
        local slot = stack[top]; stack[top] = nil; top -= 1
        local mo = slot*META_STRIDE
        local flags = buffer.readu32(self._meta,mo+M_FLAGS)
        if bit32.band(flags,F_ENABLED) ~= 0 and bit32.band(buffer.readu32(self._meta,mo+M_MASK),traversalMask) ~= 0 then
            local bo = slot*BOUNDS_STRIDE
            local sminx,sminy,sminz = buffer.readf32(self._subtreeBounds,bo),buffer.readf32(self._subtreeBounds,bo+4),buffer.readf32(self._subtreeBounds,bo+8)
            local smaxx,smaxy,smaxz = buffer.readf32(self._subtreeBounds,bo+12),buffer.readf32(self._subtreeBounds,bo+16),buffer.readf32(self._subtreeBounds,bo+20)
            if sminx <= smaxx and overlapsAabb(minx,miny,minz,maxx,maxy,maxz,sminx,sminy,sminz,smaxx,smaxy,smaxz) then
                if bit32.band(flags,F_OWN_BOUNDS) ~= 0 then
                    local ominx,ominy,ominz = buffer.readf32(self._ownWorldBounds,bo),buffer.readf32(self._ownWorldBounds,bo+4),buffer.readf32(self._ownWorldBounds,bo+8)
                    local omaxx,omaxy,omaxz = buffer.readf32(self._ownWorldBounds,bo+12),buffer.readf32(self._ownWorldBounds,bo+16),buffer.readf32(self._ownWorldBounds,bo+20)
                    if overlapsAabb(minx,miny,minz,maxx,maxy,maxz,ominx,ominy,ominz,omaxx,omaxy,omaxz) then count += 1; result[count] = self:_handle(slot) end
                end
                local child = buffer.readi32(self._meta,mo+M_FIRST_CHILD)
                while child ~= 0 do top += 1; stack[top] = child; child = buffer.readi32(self._meta,child*META_STRIDE+M_NEXT) end
            end
        end
    end
    return result
end

function Scene:collectForView(x: number, y: number, z: number, mask: number?, out: {number}?): {number}
    local traversalMask = mask or 0xffffffff
    local result = out or {}
    table.clear(result)
    local stack = self._stack
    table.clear(stack)
    local top = 0
    local root = self._firstRoot
    while root ~= 0 do top += 1; stack[top] = root; root = buffer.readi32(self._meta,root*META_STRIDE+M_NEXT) end
    local count = 0
    while top > 0 do
        local slot=stack[top]; stack[top]=nil; top-=1
        local mo=slot*META_STRIDE
        local flags=buffer.readu32(self._meta,mo+M_FLAGS)
        if bit32.band(flags,F_ENABLED) ~= 0 and bit32.band(buffer.readu32(self._meta,mo+M_MASK),traversalMask) ~= 0 then
            local bo=slot*BOUNDS_STRIDE
            local minx,miny,minz=buffer.readf32(self._subtreeBounds,bo),buffer.readf32(self._subtreeBounds,bo+4),buffer.readf32(self._subtreeBounds,bo+8)
            local maxx,maxy,maxz=buffer.readf32(self._subtreeBounds,bo+12),buffer.readf32(self._subtreeBounds,bo+16),buffer.readf32(self._subtreeBounds,bo+20)
            local distSq
            if minx <= maxx then distSq = pointAabbDistanceSq(x,y,z,minx,miny,minz,maxx,maxy,maxz) else
                local wo=slot*MAT_STRIDE
                local dx,dy,dz=buffer.readf32(self._world,wo+12)-x,buffer.readf32(self._world,wo+28)-y,buffer.readf32(self._world,wo+44)-z
                distSq=dx*dx+dy*dy+dz*dz
            end
            local ro=slot*RANGE_STRIDE
            if distSq >= buffer.readf32(self._range,ro) and distSq < buffer.readf32(self._range,ro+4) then
                count+=1; result[count]=self:_handle(slot)
                local child=buffer.readi32(self._meta,mo+M_FIRST_CHILD)
                while child ~= 0 do top+=1; stack[top]=child; child=buffer.readi32(self._meta,child*META_STRIDE+M_NEXT) end
            end
        end
    end
    return result
end

function Scene:stats(): { [string]: number }
    local perNode = META_STRIDE + LOCAL_STRIDE + MAT_STRIDE + BOUNDS_STRIDE * 3 + RANGE_STRIDE
    return {
        nodes = self._count,
        highWaterSlots = self._high,
        capacity = self._capacity,
        roots = self._roots,
        updateVersion = self._version,
        packedBytes = (self._capacity + 1) * perNode,
        bytesPerCapacityNode = perNode,
    }
end

return table.freeze({
    new = Scene.new,
    HANDLE_STRIDE = HANDLE_STRIDE,
})
