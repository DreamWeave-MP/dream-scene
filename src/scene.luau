--!strict
--!native

-- Renderer-agnostic scene/world presentation storage.
-- Nodes are integer handles into packed buffers; there is one Lua object per Scene, not per node.
-- Transform ownership is intentionally a tree. Resources referenced by consumers can still be shared.

-- 2^24: 24 bits of slot, remaining exact integer bits for generation.
local HandleStride = 16777216
local MaxSlot = HandleStride - 1

local MetaStride = 32
local MetaParent = 0
local MetaFirstChild = 4
local MetaNext = 8
local MetaPrevious = 12
local MetaGeneration = 16
local MetaMask = 20
local MetaFlags = 24
local MetaDepth = 28

local Alive = 1
local TransformDirty = 2
local OwnBounds = 4
local Enabled = 8
local BoundsDirty = 16
local OwnBoundsDirty = 32

-- Position xyz, rotation quaternion xyzw, scale xyz.
local LocalStride = 40
local LocalPositionX = 0
local LocalPositionY = 4
local LocalPositionZ = 8
local LocalRotationX = 12
local LocalRotationY = 16
local LocalRotationZ = 20
local LocalRotationW = 24
local LocalScaleX = 28
local LocalScaleY = 32
local LocalScaleZ = 36

-- A 3x4 row-major affine matrix.
local MatrixStride = 48
-- Min xyz, max xyz.
local BoundsStride = 24
-- Squared min and max view distance.
local RangeStride = 8

export type UpdateCounts = {
  nodesVisited: number,
  transformsUpdated: number,
  boundedNodes: number,
  boundsUpdated: number,
}

type Fields = {
  _capacity: number,
  _count: number,
  _high: number,
  _free: number,
  _firstRoot: number,
  _roots: number,
  _version: number,
  _batchDepth: number,
  _fullDirty: boolean,
  _meta: buffer,
  _local: buffer,
  _world: buffer,
  _localBounds: buffer,
  _ownWorldBounds: buffer,
  _subtreeBounds: buffer,
  _range: buffer,
  _stack: { number },
  _order: { number },
  _dirtyTransforms: { number },
  _dirtyTransformCount: number,
  _dirtyBounds: { number },
  _dirtyBoundsCount: number,
  _remainingBounds: { number },
}

local Scene = {}
Scene.__index = Scene

export type Scene = typeof(setmetatable({} :: Fields, Scene))

local function encode(slot: number, generation: number): number
  return generation * HandleStride + slot
end

local function decode(handle: number): (number, number)
  local generation = math.floor(handle / HandleStride)
  local slot = handle - generation * HandleStride

  return slot, generation
end

local function growBuffer(old: buffer, bytes: number): buffer
  local nextBuffer = buffer.create(bytes)
  buffer.copy(nextBuffer, 0, old, 0, buffer.len(old))

  return nextBuffer
end

local function overlapsAabb(
  leftMinX: number,
  leftMinY: number,
  leftMinZ: number,
  leftMaxX: number,
  leftMaxY: number,
  leftMaxZ: number,
  rightMinX: number,
  rightMinY: number,
  rightMinZ: number,
  rightMaxX: number,
  rightMaxY: number,
  rightMaxZ: number
): boolean
  return leftMinX <= rightMaxX
    and leftMaxX >= rightMinX
    and leftMinY <= rightMaxY
    and leftMaxY >= rightMinY
    and leftMinZ <= rightMaxZ
    and leftMaxZ >= rightMinZ
end

local function pointAabbDistanceSquared(
  pointX: number,
  pointY: number,
  pointZ: number,
  minX: number,
  minY: number,
  minZ: number,
  maxX: number,
  maxY: number,
  maxZ: number
): number
  local deltaX, deltaY, deltaZ = 0.0, 0.0, 0.0

  if pointX < minX then
    deltaX = minX - pointX
  elseif pointX > maxX then
    deltaX = pointX - maxX
  end

  if pointY < minY then
    deltaY = minY - pointY
  elseif pointY > maxY then
    deltaY = pointY - maxY
  end

  if pointZ < minZ then
    deltaZ = minZ - pointZ
  elseif pointZ > maxZ then
    deltaZ = pointZ - maxZ
  end

  return deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
end

function Scene.new(initialCapacity: number?): Scene
  local capacity = math.max(16, math.floor(initialCapacity or 256))
  assert(capacity <= MaxSlot, 'scene: initial capacity exceeds handle slot space')

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

    _meta = buffer.create((capacity + 1) * MetaStride),
    _local = buffer.create((capacity + 1) * LocalStride),
    _world = buffer.create((capacity + 1) * MatrixStride),
    _localBounds = buffer.create((capacity + 1) * BoundsStride),
    _ownWorldBounds = buffer.create((capacity + 1) * BoundsStride),
    _subtreeBounds = buffer.create((capacity + 1) * BoundsStride),
    _range = buffer.create((capacity + 1) * RangeStride),

    -- Reused scratch. No per-frame node tables are allocated by update/query paths, and none is
    -- cleared: each list's length is kept beside it, and what lies past that is stale.
    _stack = table.create(256),
    _order = table.create(256),
    _dirtyTransforms = table.create(256),
    _dirtyTransformCount = 0,
    _dirtyBounds = table.create(256),
    _dirtyBoundsCount = 0,
    _remainingBounds = table.create(64),
  }, Scene)

  return self
end

function Scene._ensure(self: Scene, slot: number)
  if slot <= self._capacity then return end

  local capacity = self._capacity

  repeat
    capacity *= 2
    assert(capacity <= MaxSlot, 'scene: node capacity exhausted')
  until capacity >= slot

  self._meta = growBuffer(self._meta, (capacity + 1) * MetaStride)
  self._local = growBuffer(self._local, (capacity + 1) * LocalStride)
  self._world = growBuffer(self._world, (capacity + 1) * MatrixStride)
  self._localBounds = growBuffer(self._localBounds, (capacity + 1) * BoundsStride)
  self._ownWorldBounds = growBuffer(self._ownWorldBounds, (capacity + 1) * BoundsStride)
  self._subtreeBounds = growBuffer(self._subtreeBounds, (capacity + 1) * BoundsStride)
  self._range = growBuffer(self._range, (capacity + 1) * RangeStride)
  self._capacity = capacity
end

function Scene._slot(self: Scene, handle: number): number
  local slot, generation = decode(handle)
  if slot <= 0 or slot > self._high then error('scene: invalid node handle', 3) end

  local metaOffset = slot * MetaStride
  local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

  if
    bit32.band(flags, Alive) == 0
    or buffer.readu32(self._meta, metaOffset + MetaGeneration) ~= generation
  then
    error('scene: stale node handle', 3)
  end

  return slot
end

function Scene.isAlive(self: Scene, handle: number): boolean
  local slot, generation = decode(handle)
  if slot <= 0 or slot > self._high then return false end

  local metaOffset = slot * MetaStride

  return bit32.band(buffer.readu32(self._meta, metaOffset + MetaFlags), Alive) ~= 0
    and buffer.readu32(self._meta, metaOffset + MetaGeneration) == generation
end

function Scene._handle(self: Scene, slot: number): number
  return encode(slot, buffer.readu32(self._meta, slot * MetaStride + MetaGeneration))
end

function Scene._queueBounds(self: Scene, slot: number)
  if self._batchDepth > 0 then
    self._fullDirty = true
    return
  end

  while slot ~= 0 do
    local metaOffset = slot * MetaStride
    local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

    if bit32.band(flags, BoundsDirty) == 0 then
      buffer.writeu32(self._meta, metaOffset + MetaFlags, bit32.bor(flags, BoundsDirty))
      local count = self._dirtyBoundsCount + 1
      self._dirtyBounds[count] = slot
      self._dirtyBoundsCount = count
    end

    slot = buffer.readi32(self._meta, metaOffset + MetaParent)
  end
end

function Scene._markTransform(self: Scene, slot: number)
  local metaOffset = slot * MetaStride
  local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

  if bit32.band(flags, TransformDirty) == 0 then
    buffer.writeu32(self._meta, metaOffset + MetaFlags, bit32.bor(flags, TransformDirty))

    if self._batchDepth == 0 then
      local count = self._dirtyTransformCount + 1
      self._dirtyTransforms[count] = slot
      self._dirtyTransformCount = count
    else
      self._fullDirty = true
    end
  elseif self._batchDepth > 0 then
    self._fullDirty = true
  end

  self:_queueBounds(slot)
end

function Scene._markOwnBounds(self: Scene, slot: number)
  local metaOffset = slot * MetaStride
  local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)
  buffer.writeu32(self._meta, metaOffset + MetaFlags, bit32.bor(flags, OwnBoundsDirty))
  self:_queueBounds(slot)
end

function Scene._updateOwnWorldBounds(self: Scene, slot: number)
  local boundsOffset = slot * BoundsStride
  local minX = buffer.readf32(self._localBounds, boundsOffset)
  local minY = buffer.readf32(self._localBounds, boundsOffset + 4)
  local minZ = buffer.readf32(self._localBounds, boundsOffset + 8)
  local maxX = buffer.readf32(self._localBounds, boundsOffset + 12)
  local maxY = buffer.readf32(self._localBounds, boundsOffset + 16)
  local maxZ = buffer.readf32(self._localBounds, boundsOffset + 20)
  local centerX, centerY, centerZ = (minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5
  local extentX, extentY, extentZ = (maxX - minX) * 0.5, (maxY - minY) * 0.5, (maxZ - minZ) * 0.5
  local worldOffset = slot * MatrixStride
  local world00 = buffer.readf32(self._world, worldOffset)
  local world01 = buffer.readf32(self._world, worldOffset + 4)
  local world02 = buffer.readf32(self._world, worldOffset + 8)
  local worldX = buffer.readf32(self._world, worldOffset + 12)
  local world10 = buffer.readf32(self._world, worldOffset + 16)
  local world11 = buffer.readf32(self._world, worldOffset + 20)
  local world12 = buffer.readf32(self._world, worldOffset + 24)
  local worldY = buffer.readf32(self._world, worldOffset + 28)
  local world20 = buffer.readf32(self._world, worldOffset + 32)
  local world21 = buffer.readf32(self._world, worldOffset + 36)
  local world22 = buffer.readf32(self._world, worldOffset + 40)
  local worldZ = buffer.readf32(self._world, worldOffset + 44)
  local worldCenterX = world00 * centerX + world01 * centerY + world02 * centerZ + worldX
  local worldCenterY = world10 * centerX + world11 * centerY + world12 * centerZ + worldY
  local worldCenterZ = world20 * centerX + world21 * centerY + world22 * centerZ + worldZ
  local worldExtentX = math.abs(world00) * extentX + math.abs(world01) * extentY + math.abs(world02) * extentZ
  local worldExtentY = math.abs(world10) * extentX + math.abs(world11) * extentY + math.abs(world12) * extentZ
  local worldExtentZ = math.abs(world20) * extentX + math.abs(world21) * extentY + math.abs(world22) * extentZ
  buffer.writef32(self._ownWorldBounds, boundsOffset, worldCenterX - worldExtentX)
  buffer.writef32(self._ownWorldBounds, boundsOffset + 4, worldCenterY - worldExtentY)
  buffer.writef32(self._ownWorldBounds, boundsOffset + 8, worldCenterZ - worldExtentZ)
  buffer.writef32(self._ownWorldBounds, boundsOffset + 12, worldCenterX + worldExtentX)
  buffer.writef32(self._ownWorldBounds, boundsOffset + 16, worldCenterY + worldExtentY)
  buffer.writef32(self._ownWorldBounds, boundsOffset + 20, worldCenterZ + worldExtentZ)
end

function Scene._recomputeSubtreeBounds(self: Scene, slot: number)
  local metaOffset = slot * MetaStride
  local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)
  local boundsOffset = slot * BoundsStride
  local minX, minY, minZ = math.huge, math.huge, math.huge
  local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

  if bit32.band(flags, OwnBounds) ~= 0 then
    minX = buffer.readf32(self._ownWorldBounds, boundsOffset)
    minY = buffer.readf32(self._ownWorldBounds, boundsOffset + 4)
    minZ = buffer.readf32(self._ownWorldBounds, boundsOffset + 8)
    maxX = buffer.readf32(self._ownWorldBounds, boundsOffset + 12)
    maxY = buffer.readf32(self._ownWorldBounds, boundsOffset + 16)
    maxZ = buffer.readf32(self._ownWorldBounds, boundsOffset + 20)
  end

  local child = buffer.readi32(self._meta, metaOffset + MetaFirstChild)

  while child ~= 0 do
    local childOffset = child * BoundsStride
    local childMinX = buffer.readf32(self._subtreeBounds, childOffset)
    local childMinY = buffer.readf32(self._subtreeBounds, childOffset + 4)
    local childMinZ = buffer.readf32(self._subtreeBounds, childOffset + 8)
    local childMaxX = buffer.readf32(self._subtreeBounds, childOffset + 12)
    local childMaxY = buffer.readf32(self._subtreeBounds, childOffset + 16)
    local childMaxZ = buffer.readf32(self._subtreeBounds, childOffset + 20)

    if childMinX <= childMaxX then
      minX, minY, minZ = math.min(minX, childMinX), math.min(minY, childMinY), math.min(minZ, childMinZ)
      maxX, maxY, maxZ = math.max(maxX, childMaxX), math.max(maxY, childMaxY), math.max(maxZ, childMaxZ)
    end

    child = buffer.readi32(self._meta, child * MetaStride + MetaNext)
  end

  buffer.writef32(self._subtreeBounds, boundsOffset, minX)
  buffer.writef32(self._subtreeBounds, boundsOffset + 4, minY)
  buffer.writef32(self._subtreeBounds, boundsOffset + 8, minZ)
  buffer.writef32(self._subtreeBounds, boundsOffset + 12, maxX)
  buffer.writef32(self._subtreeBounds, boundsOffset + 16, maxY)
  buffer.writef32(self._subtreeBounds, boundsOffset + 20, maxZ)
end

function Scene._unlink(self: Scene, slot: number)
  local metaOffset = slot * MetaStride
  local parent = buffer.readi32(self._meta, metaOffset + MetaParent)
  local previous = buffer.readi32(self._meta, metaOffset + MetaPrevious)
  local nextNode = buffer.readi32(self._meta, metaOffset + MetaNext)

  if previous ~= 0 then
    buffer.writei32(self._meta, previous * MetaStride + MetaNext, nextNode)
  elseif parent ~= 0 then
    buffer.writei32(self._meta, parent * MetaStride + MetaFirstChild, nextNode)
  else
    self._firstRoot = nextNode
  end

  if parent == 0 then self._roots -= 1 end

  if nextNode ~= 0 then buffer.writei32(self._meta, nextNode * MetaStride + MetaPrevious, previous) end

  buffer.writei32(self._meta, metaOffset + MetaParent, 0)
  buffer.writei32(self._meta, metaOffset + MetaPrevious, 0)
  buffer.writei32(self._meta, metaOffset + MetaNext, 0)
end

function Scene._link(self: Scene, slot: number, parent: number)
  local metaOffset = slot * MetaStride
  buffer.writei32(self._meta, metaOffset + MetaParent, parent)
  local depth = 0

  if parent ~= 0 then depth = buffer.readu32(self._meta, parent * MetaStride + MetaDepth) + 1 end

  buffer.writeu32(self._meta, metaOffset + MetaDepth, depth)
  buffer.writei32(self._meta, metaOffset + MetaPrevious, 0)

  if parent ~= 0 then
    local parentOffset = parent * MetaStride
    local first = buffer.readi32(self._meta, parentOffset + MetaFirstChild)
    buffer.writei32(self._meta, metaOffset + MetaNext, first)

    if first ~= 0 then buffer.writei32(self._meta, first * MetaStride + MetaPrevious, slot) end

    buffer.writei32(self._meta, parentOffset + MetaFirstChild, slot)
  else
    local first = self._firstRoot
    buffer.writei32(self._meta, metaOffset + MetaNext, first)

    if first ~= 0 then buffer.writei32(self._meta, first * MetaStride + MetaPrevious, slot) end

    self._firstRoot = slot
    self._roots += 1
  end
end

function Scene.create(self: Scene, parentHandle: number?): number
  local slot

  if self._free ~= 0 then
    slot = self._free
    self._free = buffer.readi32(self._meta, slot * MetaStride + MetaNext)
  else
    slot = self._high + 1
    self:_ensure(slot)
    self._high = slot
    buffer.writeu32(self._meta, slot * MetaStride + MetaGeneration, 1)
  end

  local metaOffset = slot * MetaStride
  local generation = buffer.readu32(self._meta, metaOffset + MetaGeneration)

  if generation == 0 then
    generation = 1
    buffer.writeu32(self._meta, metaOffset + MetaGeneration, generation)
  end

  buffer.writei32(self._meta, metaOffset + MetaFirstChild, 0)
  buffer.writeu32(self._meta, metaOffset + MetaMask, 0xffffffff)

  if self._batchDepth > 0 then
    buffer.writeu32(self._meta, metaOffset + MetaFlags, bit32.bor(Alive, TransformDirty, Enabled))
    self._fullDirty = true
  else
    buffer.writeu32(self._meta, metaOffset + MetaFlags, bit32.bor(Alive, TransformDirty, Enabled, BoundsDirty))
    local transformCount, boundsCount = self._dirtyTransformCount + 1, self._dirtyBoundsCount + 1
    self._dirtyTransforms[transformCount] = slot
    self._dirtyTransformCount = transformCount
    self._dirtyBounds[boundsCount] = slot
    self._dirtyBoundsCount = boundsCount
  end

  local localOffset = slot * LocalStride
  buffer.writef32(self._local, localOffset + LocalPositionX, 0)
  buffer.writef32(self._local, localOffset + LocalPositionY, 0)
  buffer.writef32(self._local, localOffset + LocalPositionZ, 0)
  buffer.writef32(self._local, localOffset + LocalRotationX, 0)
  buffer.writef32(self._local, localOffset + LocalRotationY, 0)
  buffer.writef32(self._local, localOffset + LocalRotationZ, 0)
  buffer.writef32(self._local, localOffset + LocalRotationW, 1)
  buffer.writef32(self._local, localOffset + LocalScaleX, 1)
  buffer.writef32(self._local, localOffset + LocalScaleY, 1)
  buffer.writef32(self._local, localOffset + LocalScaleZ, 1)

  local rangeOffset = slot * RangeStride
  buffer.writef32(self._range, rangeOffset, 0)
  buffer.writef32(self._range, rangeOffset + 4, math.huge)

  self:_link(slot, 0)
  self._count += 1
  local handle = encode(slot, generation)

  if parentHandle then self:setParent(handle, parentHandle) end

  return handle
end

function Scene.destroy(self: Scene, handle: number): number
  local root = self:_slot(handle)
  local oldParent = buffer.readi32(self._meta, root * MetaStride + MetaParent)
  self:_unlink(root)

  if oldParent ~= 0 then self:_queueBounds(oldParent) end

  local stack = self._stack
  local order = self._order
  local top = 1
  stack[1] = root
  local count = 0

  while top > 0 do
    local slot = stack[top]
    top -= 1
    count += 1
    order[count] = slot
    local child = buffer.readi32(self._meta, slot * MetaStride + MetaFirstChild)

    while child ~= 0 do
      top += 1
      stack[top] = child
      child = buffer.readi32(self._meta, child * MetaStride + MetaNext)
    end
  end

  for index = 1, count do
    local slot = order[index]
    local metaOffset = slot * MetaStride
    local generation = buffer.readu32(self._meta, metaOffset + MetaGeneration) + 1

    if generation >= 0x1fffffff then generation = 1 end

    buffer.writeu32(self._meta, metaOffset + MetaGeneration, generation)
    buffer.writeu32(self._meta, metaOffset + MetaFlags, 0)
    buffer.writei32(self._meta, metaOffset + MetaParent, 0)
    buffer.writei32(self._meta, metaOffset + MetaFirstChild, 0)
    buffer.writei32(self._meta, metaOffset + MetaPrevious, 0)
    buffer.writei32(self._meta, metaOffset + MetaNext, self._free)
    self._free = slot
  end

  self._count -= count

  return count
end

function Scene.setParent(self: Scene, handle: number, parentHandle: number?)
  local slot = self:_slot(handle)
  local parent = 0

  if parentHandle then
    parent = self:_slot(parentHandle)
    assert(parent ~= slot, 'scene: node cannot parent itself')
    local ancestor = parent

    while ancestor ~= 0 do
      assert(ancestor ~= slot, 'scene: parenting would create a cycle')
      ancestor = buffer.readi32(self._meta, ancestor * MetaStride + MetaParent)
    end
  end

  local current = buffer.readi32(self._meta, slot * MetaStride + MetaParent)
  if current == parent then return end

  self:_unlink(slot)

  if current ~= 0 then self:_queueBounds(current) end

  self:_link(slot, parent)
  self:_markTransform(slot)
end

function Scene.parent(self: Scene, handle: number): number?
  local slot = self:_slot(handle)
  local parent = buffer.readi32(self._meta, slot * MetaStride + MetaParent)
  if parent == 0 then return nil end

  return self:_handle(parent)
end

function Scene.setTransform(
  self: Scene,
  handle: number,
  positionX: number,
  positionY: number,
  positionZ: number,
  rotationX: number,
  rotationY: number,
  rotationZ: number,
  rotationW: number,
  scaleX: number,
  scaleY: number,
  scaleZ: number
)
  local slot = self:_slot(handle)
  local localOffset = slot * LocalStride
  buffer.writef32(self._local, localOffset + LocalPositionX, positionX)
  buffer.writef32(self._local, localOffset + LocalPositionY, positionY)
  buffer.writef32(self._local, localOffset + LocalPositionZ, positionZ)
  buffer.writef32(self._local, localOffset + LocalRotationX, rotationX)
  buffer.writef32(self._local, localOffset + LocalRotationY, rotationY)
  buffer.writef32(self._local, localOffset + LocalRotationZ, rotationZ)
  buffer.writef32(self._local, localOffset + LocalRotationW, rotationW)
  buffer.writef32(self._local, localOffset + LocalScaleX, scaleX)
  buffer.writef32(self._local, localOffset + LocalScaleY, scaleY)
  buffer.writef32(self._local, localOffset + LocalScaleZ, scaleZ)
  self:_markTransform(slot)
end

function Scene.setPosition(self: Scene, handle: number, positionX: number, positionY: number, positionZ: number)
  local slot = self:_slot(handle)
  local localOffset = slot * LocalStride
  buffer.writef32(self._local, localOffset + LocalPositionX, positionX)
  buffer.writef32(self._local, localOffset + LocalPositionY, positionY)
  buffer.writef32(self._local, localOffset + LocalPositionZ, positionZ)
  self:_markTransform(slot)
end

function Scene.setRotation(
  self: Scene,
  handle: number,
  rotationX: number,
  rotationY: number,
  rotationZ: number,
  rotationW: number
)
  local slot = self:_slot(handle)
  local localOffset = slot * LocalStride
  buffer.writef32(self._local, localOffset + LocalRotationX, rotationX)
  buffer.writef32(self._local, localOffset + LocalRotationY, rotationY)
  buffer.writef32(self._local, localOffset + LocalRotationZ, rotationZ)
  buffer.writef32(self._local, localOffset + LocalRotationW, rotationW)
  self:_markTransform(slot)
end

function Scene.setScale(self: Scene, handle: number, scaleX: number, scaleY: number, scaleZ: number)
  local slot = self:_slot(handle)
  local localOffset = slot * LocalStride
  buffer.writef32(self._local, localOffset + LocalScaleX, scaleX)
  buffer.writef32(self._local, localOffset + LocalScaleY, scaleY)
  buffer.writef32(self._local, localOffset + LocalScaleZ, scaleZ)
  self:_markTransform(slot)
end

function Scene.setBounds(
  self: Scene,
  handle: number,
  minX: number,
  minY: number,
  minZ: number,
  maxX: number,
  maxY: number,
  maxZ: number
)
  assert(minX <= maxX and minY <= maxY and minZ <= maxZ, 'scene: invalid bounds')
  local slot = self:_slot(handle)
  local boundsOffset = slot * BoundsStride
  buffer.writef32(self._localBounds, boundsOffset, minX)
  buffer.writef32(self._localBounds, boundsOffset + 4, minY)
  buffer.writef32(self._localBounds, boundsOffset + 8, minZ)
  buffer.writef32(self._localBounds, boundsOffset + 12, maxX)
  buffer.writef32(self._localBounds, boundsOffset + 16, maxY)
  buffer.writef32(self._localBounds, boundsOffset + 20, maxZ)
  local metaOffset = slot * MetaStride
  buffer.writeu32(
    self._meta,
    metaOffset + MetaFlags,
    bit32.bor(buffer.readu32(self._meta, metaOffset + MetaFlags), OwnBounds)
  )
  self:_markOwnBounds(slot)
end

function Scene.clearBounds(self: Scene, handle: number)
  local slot = self:_slot(handle)
  local metaOffset = slot * MetaStride
  local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)
  flags = bit32.band(flags, bit32.bnot(OwnBounds))
  buffer.writeu32(self._meta, metaOffset + MetaFlags, flags)
  self:_markOwnBounds(slot)
end

function Scene.setMask(self: Scene, handle: number, mask: number)
  local slot = self:_slot(handle)
  buffer.writeu32(self._meta, slot * MetaStride + MetaMask, mask)
end

function Scene.setEnabled(self: Scene, handle: number, enabled: boolean)
  local slot = self:_slot(handle)
  local metaOffset = slot * MetaStride
  local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

  if enabled then
    flags = bit32.bor(flags, Enabled)
  else
    flags = bit32.band(flags, bit32.bnot(Enabled))
  end

  buffer.writeu32(self._meta, metaOffset + MetaFlags, flags)
end

function Scene.setRange(self: Scene, handle: number, minDistance: number, maxDistance: number)
  assert(minDistance >= 0 and maxDistance >= minDistance, 'scene: invalid LOD range')
  local slot = self:_slot(handle)
  local rangeOffset = slot * RangeStride
  buffer.writef32(self._range, rangeOffset, minDistance * minDistance)
  buffer.writef32(
    self._range,
    rangeOffset + 4,
    if maxDistance == math.huge then math.huge else maxDistance * maxDistance
  )
end

function Scene.getWorldPosition(self: Scene, handle: number): (number, number, number)
  local slot = self:_slot(handle)
  local worldOffset = slot * MatrixStride

  return buffer.readf32(self._world, worldOffset + 12),
    buffer.readf32(self._world, worldOffset + 28),
    buffer.readf32(self._world, worldOffset + 44)
end

function Scene.beginBatch(self: Scene)
  self._batchDepth += 1
end

function Scene.endBatch(self: Scene)
  assert(self._batchDepth > 0, 'scene: endBatch without beginBatch')
  self._batchDepth -= 1
end

function Scene.update(self: Scene): UpdateCounts
  assert(self._batchDepth == 0, 'scene: update during batch')
  local dirtyTransforms = self._dirtyTransforms
  local dirtyBounds = self._dirtyBounds
  local dirtyTransformCount, dirtyBoundsCount = self._dirtyTransformCount, self._dirtyBoundsCount

  if not self._fullDirty and dirtyTransformCount == 0 and dirtyBoundsCount == 0 then
    return { nodesVisited = 0, transformsUpdated = 0, boundedNodes = 0, boundsUpdated = 0 }
  end

  local stack = self._stack
  local order = self._order
  local top = 0

  if self._fullDirty then
    local root = self._firstRoot

    while root ~= 0 do
      top += 1
      stack[top] = root
      root = buffer.readi32(self._meta, root * MetaStride + MetaNext)
    end
  else
    -- Collapse direct transform dirties to the highest dirty roots before clearing any flags.
    for index = 1, dirtyTransformCount do
      local slot = dirtyTransforms[index]
      local metaOffset = slot * MetaStride
      local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

      if bit32.band(flags, bit32.bor(Alive, TransformDirty)) ~= bit32.bor(Alive, TransformDirty) then
        continue
      end

      local parent = buffer.readi32(self._meta, metaOffset + MetaParent)
      local covered = false

      while parent ~= 0 do
        local parentFlags = buffer.readu32(self._meta, parent * MetaStride + MetaFlags)

        if bit32.band(parentFlags, TransformDirty) ~= 0 then
          covered = true
          break
        end

        parent = buffer.readi32(self._meta, parent * MetaStride + MetaParent)
      end

      if not covered then
        top += 1
        stack[top] = slot
      end
    end
  end

  local visited = 0
  local boundedNodes = 0

  -- Every descendant of a dirty transform root inherits a new world transform.
  while top > 0 do
    local slot = stack[top]
    top -= 1
    local metaOffset = slot * MetaStride
    local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)
    visited += 1
    order[visited] = slot

    local parent = buffer.readi32(self._meta, metaOffset + MetaParent)
    local depth = 0

    if parent ~= 0 then depth = buffer.readu32(self._meta, parent * MetaStride + MetaDepth) + 1 end

    buffer.writeu32(self._meta, metaOffset + MetaDepth, depth)

    local localOffset = slot * LocalStride
    local positionX = buffer.readf32(self._local, localOffset + LocalPositionX)
    local positionY = buffer.readf32(self._local, localOffset + LocalPositionY)
    local positionZ = buffer.readf32(self._local, localOffset + LocalPositionZ)
    local rotationX = buffer.readf32(self._local, localOffset + LocalRotationX)
    local rotationY = buffer.readf32(self._local, localOffset + LocalRotationY)
    local rotationZ = buffer.readf32(self._local, localOffset + LocalRotationZ)
    local rotationW = buffer.readf32(self._local, localOffset + LocalRotationW)
    local scaleX = buffer.readf32(self._local, localOffset + LocalScaleX)
    local scaleY = buffer.readf32(self._local, localOffset + LocalScaleY)
    local scaleZ = buffer.readf32(self._local, localOffset + LocalScaleZ)
    local xx, yy, zz = rotationX * rotationX, rotationY * rotationY, rotationZ * rotationZ
    local xy, xz, yz = rotationX * rotationY, rotationX * rotationZ, rotationY * rotationZ
    local xw, yw, zw = rotationX * rotationW, rotationY * rotationW, rotationZ * rotationW
    local local00 = (1 - 2 * (yy + zz)) * scaleX
    local local01 = (2 * (xy - zw)) * scaleY
    local local02 = (2 * (xz + yw)) * scaleZ
    local local10 = (2 * (xy + zw)) * scaleX
    local local11 = (1 - 2 * (xx + zz)) * scaleY
    local local12 = (2 * (yz - xw)) * scaleZ
    local local20 = (2 * (xz - yw)) * scaleX
    local local21 = (2 * (yz + xw)) * scaleY
    local local22 = (1 - 2 * (xx + yy)) * scaleZ
    local worldOffset = slot * MatrixStride

    if parent == 0 then
      buffer.writef32(self._world, worldOffset, local00)
      buffer.writef32(self._world, worldOffset + 4, local01)
      buffer.writef32(self._world, worldOffset + 8, local02)
      buffer.writef32(self._world, worldOffset + 12, positionX)
      buffer.writef32(self._world, worldOffset + 16, local10)
      buffer.writef32(self._world, worldOffset + 20, local11)
      buffer.writef32(self._world, worldOffset + 24, local12)
      buffer.writef32(self._world, worldOffset + 28, positionY)
      buffer.writef32(self._world, worldOffset + 32, local20)
      buffer.writef32(self._world, worldOffset + 36, local21)
      buffer.writef32(self._world, worldOffset + 40, local22)
      buffer.writef32(self._world, worldOffset + 44, positionZ)
    else
      local parentOffset = parent * MatrixStride
      local parent00 = buffer.readf32(self._world, parentOffset)
      local parent01 = buffer.readf32(self._world, parentOffset + 4)
      local parent02 = buffer.readf32(self._world, parentOffset + 8)
      local parentX = buffer.readf32(self._world, parentOffset + 12)
      local parent10 = buffer.readf32(self._world, parentOffset + 16)
      local parent11 = buffer.readf32(self._world, parentOffset + 20)
      local parent12 = buffer.readf32(self._world, parentOffset + 24)
      local parentY = buffer.readf32(self._world, parentOffset + 28)
      local parent20 = buffer.readf32(self._world, parentOffset + 32)
      local parent21 = buffer.readf32(self._world, parentOffset + 36)
      local parent22 = buffer.readf32(self._world, parentOffset + 40)
      local parentZ = buffer.readf32(self._world, parentOffset + 44)
      buffer.writef32(self._world, worldOffset, parent00 * local00 + parent01 * local10 + parent02 * local20)
      buffer.writef32(self._world, worldOffset + 4, parent00 * local01 + parent01 * local11 + parent02 * local21)
      buffer.writef32(self._world, worldOffset + 8, parent00 * local02 + parent01 * local12 + parent02 * local22)
      buffer.writef32(
        self._world,
        worldOffset + 12,
        parent00 * positionX + parent01 * positionY + parent02 * positionZ + parentX
      )
      buffer.writef32(self._world, worldOffset + 16, parent10 * local00 + parent11 * local10 + parent12 * local20)
      buffer.writef32(self._world, worldOffset + 20, parent10 * local01 + parent11 * local11 + parent12 * local21)
      buffer.writef32(self._world, worldOffset + 24, parent10 * local02 + parent11 * local12 + parent12 * local22)
      buffer.writef32(
        self._world,
        worldOffset + 28,
        parent10 * positionX + parent11 * positionY + parent12 * positionZ + parentY
      )
      buffer.writef32(self._world, worldOffset + 32, parent20 * local00 + parent21 * local10 + parent22 * local20)
      buffer.writef32(self._world, worldOffset + 36, parent20 * local01 + parent21 * local11 + parent22 * local21)
      buffer.writef32(self._world, worldOffset + 40, parent20 * local02 + parent21 * local12 + parent22 * local22)
      buffer.writef32(
        self._world,
        worldOffset + 44,
        parent20 * positionX + parent21 * positionY + parent22 * positionZ + parentZ
      )
    end

    if bit32.band(flags, OwnBounds) ~= 0 then
      self:_updateOwnWorldBounds(slot)
      boundedNodes += 1
    end

    flags = bit32.band(flags, bit32.bnot(bit32.bor(TransformDirty, OwnBoundsDirty)))
    buffer.writeu32(self._meta, metaOffset + MetaFlags, flags)

    local child = buffer.readi32(self._meta, metaOffset + MetaFirstChild)

    while child ~= 0 do
      top += 1
      stack[top] = child
      child = buffer.readi32(self._meta, child * MetaStride + MetaNext)
    end
  end

  -- Dirty transform subtrees are complete; fold their bounds bottom-up.
  local boundsUpdated = 0

  for index = visited, 1, -1 do
    local slot = order[index]
    self:_recomputeSubtreeBounds(slot)
    boundsUpdated += 1
    local metaOffset = slot * MetaStride
    local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)
    buffer.writeu32(self._meta, metaOffset + MetaFlags, bit32.band(flags, bit32.bnot(BoundsDirty)))
  end

  -- What remains are ancestors of changed subtrees or bounds-only edits. Depth order guarantees
  -- children first.
  local remaining = self._remainingBounds
  table.clear(remaining)

  for index = 1, dirtyBoundsCount do
    local slot = dirtyBounds[index]
    local flags = buffer.readu32(self._meta, slot * MetaStride + MetaFlags)

    if bit32.band(flags, bit32.bor(Alive, BoundsDirty)) == bit32.bor(Alive, BoundsDirty) then
      remaining[#remaining + 1] = slot
    end
  end

  table.sort(remaining, function(left: number, right: number): boolean
    return buffer.readu32(self._meta, left * MetaStride + MetaDepth)
      > buffer.readu32(self._meta, right * MetaStride + MetaDepth)
  end)

  for index = 1, #remaining do
    local slot = remaining[index]
    local metaOffset = slot * MetaStride
    local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

    if bit32.band(flags, OwnBoundsDirty) ~= 0 then
      if bit32.band(flags, OwnBounds) ~= 0 then
        self:_updateOwnWorldBounds(slot)
        boundedNodes += 1
      end

      flags = bit32.band(flags, bit32.bnot(OwnBoundsDirty))
    end

    self:_recomputeSubtreeBounds(slot)
    boundsUpdated += 1
    flags = bit32.band(flags, bit32.bnot(BoundsDirty))
    buffer.writeu32(self._meta, metaOffset + MetaFlags, flags)
  end

  self._dirtyTransformCount = 0
  self._dirtyBoundsCount = 0
  self._fullDirty = false
  self._version += 1

  return {
    nodesVisited = visited,
    transformsUpdated = visited,
    boundedNodes = boundedNodes,
    boundsUpdated = boundsUpdated,
  }
end

function Scene.collect(self: Scene, mask: number?, out: { number }?): { number }
  local traversalMask = mask or 0xffffffff
  local result = out or {}
  table.clear(result)
  local stack = self._stack
  local top = 0
  local root = self._firstRoot

  while root ~= 0 do
    top += 1
    stack[top] = root
    root = buffer.readi32(self._meta, root * MetaStride + MetaNext)
  end

  local count = 0

  while top > 0 do
    local slot = stack[top]
    top -= 1
    local metaOffset = slot * MetaStride
    local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

    if
      bit32.band(flags, Enabled) == 0
      or bit32.band(buffer.readu32(self._meta, metaOffset + MetaMask), traversalMask) == 0
    then
      continue
    end

    count += 1
    result[count] = self:_handle(slot)
    local child = buffer.readi32(self._meta, metaOffset + MetaFirstChild)

    while child ~= 0 do
      top += 1
      stack[top] = child
      child = buffer.readi32(self._meta, child * MetaStride + MetaNext)
    end
  end

  return result
end

function Scene.queryAabb(
  self: Scene,
  minX: number,
  minY: number,
  minZ: number,
  maxX: number,
  maxY: number,
  maxZ: number,
  mask: number?,
  out: { number }?
): { number }
  local traversalMask = mask or 0xffffffff
  local result = out or {}
  table.clear(result)
  local stack = self._stack
  local top = 0
  local root = self._firstRoot

  while root ~= 0 do
    top += 1
    stack[top] = root
    root = buffer.readi32(self._meta, root * MetaStride + MetaNext)
  end

  local count = 0

  while top > 0 do
    local slot = stack[top]
    top -= 1
    local metaOffset = slot * MetaStride
    local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

    if
      bit32.band(flags, Enabled) == 0
      or bit32.band(buffer.readu32(self._meta, metaOffset + MetaMask), traversalMask) == 0
    then
      continue
    end

    local boundsOffset = slot * BoundsStride
    local subtreeMinX = buffer.readf32(self._subtreeBounds, boundsOffset)
    local subtreeMinY = buffer.readf32(self._subtreeBounds, boundsOffset + 4)
    local subtreeMinZ = buffer.readf32(self._subtreeBounds, boundsOffset + 8)
    local subtreeMaxX = buffer.readf32(self._subtreeBounds, boundsOffset + 12)
    local subtreeMaxY = buffer.readf32(self._subtreeBounds, boundsOffset + 16)
    local subtreeMaxZ = buffer.readf32(self._subtreeBounds, boundsOffset + 20)

    if
      not (
        subtreeMinX <= subtreeMaxX
        and overlapsAabb(
          minX,
          minY,
          minZ,
          maxX,
          maxY,
          maxZ,
          subtreeMinX,
          subtreeMinY,
          subtreeMinZ,
          subtreeMaxX,
          subtreeMaxY,
          subtreeMaxZ
        )
      )
    then
      continue
    end

    if bit32.band(flags, OwnBounds) ~= 0 then
      local ownMinX = buffer.readf32(self._ownWorldBounds, boundsOffset)
      local ownMinY = buffer.readf32(self._ownWorldBounds, boundsOffset + 4)
      local ownMinZ = buffer.readf32(self._ownWorldBounds, boundsOffset + 8)
      local ownMaxX = buffer.readf32(self._ownWorldBounds, boundsOffset + 12)
      local ownMaxY = buffer.readf32(self._ownWorldBounds, boundsOffset + 16)
      local ownMaxZ = buffer.readf32(self._ownWorldBounds, boundsOffset + 20)

      if overlapsAabb(minX, minY, minZ, maxX, maxY, maxZ, ownMinX, ownMinY, ownMinZ, ownMaxX, ownMaxY, ownMaxZ) then
        count += 1
        result[count] = self:_handle(slot)
      end
    end

    local child = buffer.readi32(self._meta, metaOffset + MetaFirstChild)

    while child ~= 0 do
      top += 1
      stack[top] = child
      child = buffer.readi32(self._meta, child * MetaStride + MetaNext)
    end
  end

  return result
end

function Scene.collectForView(
  self: Scene,
  viewX: number,
  viewY: number,
  viewZ: number,
  mask: number?,
  out: { number }?
): { number }
  local traversalMask = mask or 0xffffffff
  local result = out or {}
  table.clear(result)
  local stack = self._stack
  local top = 0
  local root = self._firstRoot

  while root ~= 0 do
    top += 1
    stack[top] = root
    root = buffer.readi32(self._meta, root * MetaStride + MetaNext)
  end

  local count = 0

  while top > 0 do
    local slot = stack[top]
    top -= 1
    local metaOffset = slot * MetaStride
    local flags = buffer.readu32(self._meta, metaOffset + MetaFlags)

    if
      bit32.band(flags, Enabled) == 0
      or bit32.band(buffer.readu32(self._meta, metaOffset + MetaMask), traversalMask) == 0
    then
      continue
    end

    local boundsOffset = slot * BoundsStride
    local minX = buffer.readf32(self._subtreeBounds, boundsOffset)
    local minY = buffer.readf32(self._subtreeBounds, boundsOffset + 4)
    local minZ = buffer.readf32(self._subtreeBounds, boundsOffset + 8)
    local maxX = buffer.readf32(self._subtreeBounds, boundsOffset + 12)
    local maxY = buffer.readf32(self._subtreeBounds, boundsOffset + 16)
    local maxZ = buffer.readf32(self._subtreeBounds, boundsOffset + 20)
    local distanceSquared

    if minX <= maxX then
      distanceSquared = pointAabbDistanceSquared(viewX, viewY, viewZ, minX, minY, minZ, maxX, maxY, maxZ)
    else
      local worldOffset = slot * MatrixStride
      local deltaX = buffer.readf32(self._world, worldOffset + 12) - viewX
      local deltaY = buffer.readf32(self._world, worldOffset + 28) - viewY
      local deltaZ = buffer.readf32(self._world, worldOffset + 44) - viewZ
      distanceSquared = deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
    end

    local rangeOffset = slot * RangeStride

    -- Written as the range it must be inside: a distance that is not a number is inside none.
    if
      not (
        distanceSquared >= buffer.readf32(self._range, rangeOffset)
        and distanceSquared < buffer.readf32(self._range, rangeOffset + 4)
      )
    then
      continue
    end

    count += 1
    result[count] = self:_handle(slot)
    local child = buffer.readi32(self._meta, metaOffset + MetaFirstChild)

    while child ~= 0 do
      top += 1
      stack[top] = child
      child = buffer.readi32(self._meta, child * MetaStride + MetaNext)
    end
  end

  return result
end

function Scene.stats(self: Scene): { [string]: number }
  local perNode = MetaStride + LocalStride + MatrixStride + BoundsStride * 3 + RangeStride

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

return table.freeze {
  new = Scene.new,
  HANDLE_STRIDE = HandleStride,
}
