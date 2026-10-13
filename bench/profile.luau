--!strict
--!native
-- One workload of a flat world of cells, run in a loop for `jess run --profile`:
-- `jess run --profile --package . bench/profile.luau [mode] [nodes] [iterations]`. The modes are
-- idle, dirtyleaf, dirtyroot, dirty1pct, collect, query-small, query-world, view and churn.
local scene = require '@dream/scene'

local mode: string = arg[1] or 'dirtyroot'
local nodes = tonumber(arg[2]) or 100000
local iterations = tonumber(arg[3]) or 100
local world = scene.new(nodes)
local cellCount = math.max(1, nodes // 64)
local cells, leaves = table.create(cellCount), table.create(nodes - cellCount)
local out: { number } = {}

world:beginBatch()

for index = 1, cellCount do
  local cell = world:create()
  cells[index] = cell
  world:setPosition(cell, index % 64 * 128, index // 64 * 128, 0)
end

for index = 1, nodes - cellCount do
  local leaf = world:create(cells[(index - 1) % cellCount + 1])
  leaves[index] = leaf
  world:setPosition(leaf, index % 16 * 4, index // 16 % 16 * 4, index % 7 * 0.5)
  world:setBounds(leaf, -1, -1, -1, 1, 1, 1)

  if index % 4 == 0 then world:setRange(leaf, 0, 512) end
end

world:endBatch()
world:update()

--- Moves a node a little from where the last update put it, as a local position.
local function nudge(node: number, distance: number)
  local column, row, level = world:getWorldPosition(node)
  world:setPosition(node, column + distance, row, level)
end

if mode == 'idle' then
  for _ = 1, iterations do
    world:update()
  end
elseif mode == 'dirtyleaf' then
  for iteration = 1, iterations do
    nudge(leaves[(iteration - 1) % #leaves + 1], 0.01)
    world:update()
  end
elseif mode == 'dirtyroot' then
  for iteration = 1, iterations do
    nudge(cells[(iteration - 1) % #cells + 1], 0.01)
    world:update()
  end
elseif mode == 'dirty1pct' then
  local count = math.max(1, #leaves // 100)

  for iteration = 1, iterations do
    for step = 1, count do
      nudge(leaves[(step * 97 + iteration - 2) % #leaves + 1], 0.001)
    end

    world:update()
  end
elseif mode == 'collect' then
  for _ = 1, iterations do
    world:collect(0xffffffff, out)
  end
elseif mode == 'query-small' then
  for _ = 1, iterations do
    world:queryAabb(0, 0, -10, 64, 64, 10, 0xffffffff, out)
  end
elseif mode == 'query-world' then
  for _ = 1, iterations do
    world:queryAabb(-100000, -100000, -100000, 100000, 100000, 100000, 0xffffffff, out)
  end
elseif mode == 'view' then
  for _ = 1, iterations do
    world:collectForView(0, 0, 0, 0xffffffff, out)
  end
elseif mode == 'churn' then
  for iteration = 1, iterations do
    world:destroy(world:create(cells[(iteration - 1) % #cells + 1]))
  end

  world:update()
else
  error(`unknown mode {mode}`)
end

print(mode, nodes, iterations, #out, world:stats().nodes)
