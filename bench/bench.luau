--!strict
-- dream.scene, timed from Luau: building scenes, updates after edits of every size, traversals,
-- box queries, view collection and churn, on a flat world of cells and on a tree seven levels
-- deep. Run by `jess run --package . bench/bench.luau [filter] [results]` on a release build.
-- Prints one line per workload: its name, a tab, and the seconds one call takes, a call being
-- what the name says. Every workload's answer is checked against what 0.1.0 answers, before the
-- first batch and after the last, so a path that stopped doing the work, or does different work,
-- fails here instead of posting a time. With `results` as the second argument each workload's
-- answer is printed instead of timed, which is how the table of expectations is made.
local scene = require '@dream/scene'

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- one says nothing about what ships.
if not jess.bench.verified then
  error('scene bench: this jess was built without the verified toolchain: measure on a release build', 0)
end

local filter: string?, mode: string? = ...
local only = if filter and filter ~= '' then filter else nil
local printing = mode == 'results'

type World = typeof(scene.new())
type Counts = { nodesVisited: number, transformsUpdated: number, boundedNodes: number, boundsUpdated: number }
type Flat = { world: World, cells: { number }, leaves: { number } }

-- What every workload answers, as 0.1.0 answers it.
local Expected: { [string]: string } = {
  ['build 20,000 nodes one at a time'] = '20000 handles, digest 2185512540; 458 in a box',
  ['build 20,000 nodes in a batch'] = '20000 handles, digest 2185512540; 458 in a box',
  ['build 100,000 nodes in a batch'] = '100000 handles, digest 4172637211; 414 in a box',
  ['flat: update with nothing to do'] = '0 placed, 0 boxed, 0 folded',
  ['flat: move a leaf and back, an update after each'] = '1 placed, 1 boxed, 2 folded; back, 1 placed, 1 boxed, 2 folded',
  ['flat: move a cell of 64 and back, an update after each'] = '64 placed, 63 boxed, 64 folded; back, 64 placed, 63 boxed, 64 folded',
  ['flat: move 1,000 leaves of 1,000 cells and back, an update after each'] = '1000 placed, 1000 boxed, 2000 folded; back, 1000 placed, 1000 boxed, 2000 folded',
  ['flat: resize the boxes of 1,000 leaves and back, an update after each'] = '0 placed, 1000 boxed, 2000 folded; back, 0 placed, 1000 boxed, 2000 folded',
  ['flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each'] = '0 placed, 10100 boxed, 11562 folded; back, 0 placed, 10000 boxed, 11562 folded',
  ['flat: move a leaf in a batch and realize all 100,000 nodes'] = '100000 placed, 98438 boxed, 100000 folded',
  ['flat: collect every node'] = '100000 handles, digest 4172637211',
  ['flat: collect through a mask half the cells wear'] = '50000 handles, digest 2960953772',
  ['flat: query a box around one cell'] = '64 handles, digest 4263440640',
  ['flat: query a box around one cell, into a table that held every node'] = '64 handles, digest 4263440640',
  ['flat: query a box around a hundred cells'] = '6300 handles, digest 2335789730',
  ['flat: query a box around the world'] = '98438 handles, digest 1444051125',
  ['flat: collect for a view from a corner'] = '75611 handles, digest 30566877',
  ['flat: collect for a view from the middle, through a mask'] = '26152 handles, digest 2175070007',
  ['tree: move 500 nodes of four depths and back, an update after each'] = '4316 placed, 3665 boxed, 5141 folded; back, 4316 placed, 3665 boxed, 5141 folded',
  ['tree: resize the boxes of 2,000 leaves and back, an update after each'] = '0 placed, 2000 boxed, 5534 folded; back, 0 placed, 2000 boxed, 5534 folded',
  ['tree: collect every node'] = '55987 handles, digest 2244611330',
  ['tree: query a box around one branch'] = '750 handles, digest 3748448313',
  ['tree: collect for a view from beside the root'] = '43527 handles, digest 122020278',
  ['churn: create and destroy 1,000 leaves, then update'] = '0 placed, 0 boxed, 312 folded; 20000 nodes, 312 roots, 20001 slots, 20000 collected',
  ['churn: move 1,000 leaves to other cells and back, an update after each'] = '1000 placed, 1000 boxed, 1312 folded; back, 1000 placed, 1000 boxed, 1312 folded; 20000 nodes, 312 roots, 20001 slots, 20000 collected',
  ['churn: destroy 16 cells of 64 and build them again, then update'] = '1025 removed; 1025 placed, 1009 boxed, 1025 folded; 20000 nodes, 312 roots, 20001 slots, 20000 collected',
}
local Everything = 0xffffffff
local Fanout = 6

-- How many nodes of each level of the tree the tree's move workload moves; none above the fourth.
local Moved = { 0, 0, 0, 5, 50, 150, 295 }

local function median(samples: { number }): number
  table.sort(samples)

  return samples[(#samples + 1) // 2]
end

local function wanted(name: string): boolean
  return not only or string.find(name, only, 1, true) ~= nil
end

local function check(name: string, answer: string)
  if answer == Expected[name] then return end

  error(`scene bench: {name}: answered {answer}, not {Expected[name]}`, 0)
end

--- Seconds per call of `body`: warmed up, then the median of seven batches of a size that takes
--- about a tenth of a second, with a full collection before each. `audit` reads what the body
--- left, outside the time, after the first call and after the last.
local function timed(name: string, body: () -> (), audit: () -> string)
  if not wanted(name) then return end

  jess.bench.collect()
  body()

  if printing then
    print(`  ['{name}'] = '{audit()}',`)
    return
  end

  check(name, audit())
  local calls, elapsed = 1, 0

  -- A call can be shorter than the clock can tell: grow the trial until it takes five milliseconds.
  while true do
    local start = os.clock()

    for _ = 1, calls do
      body()
    end

    elapsed = os.clock() - start
    if elapsed >= 0.005 then break end

    calls *= 4
  end

  calls = math.max(1, math.floor(0.1 * calls / elapsed))
  local samples = table.create(7)

  for batch = 1, 7 do
    jess.bench.collect()
    local start = os.clock()

    for _ = 1, calls do
      body()
    end

    samples[batch] = (os.clock() - start) / calls
  end

  check(name, audit())
  print(`{name}\t{string.format('%.9f', median(samples))}`)
end

local function placed(counts: Counts): string
  return `{counts.nodesVisited} placed, {counts.boundedNodes} boxed, {counts.boundsUpdated} folded`
end

--- How many handles a traversal answered with, and a digest of them in the order it gave.
local function listed(handles: { number }): string
  local digest = 0

  for _, handle in handles do
    digest = (digest * 31 + handle) % 4294967291
  end

  return `{#handles} handles, digest {digest}`
end

--- Times a traversal into a table of its own, or into `reused`, and answers with what it listed.
local function walked(name: string, walk: (out: { number }) -> (), reused: { number }?)
  local out: { number } = reused or {}

  timed(name, function() walk(out) end, function(): string
    return listed(out)
  end)
end

local function cellPosition(index: number): (number, number, number)
  return index % 64 * 128, index // 64 * 128, 0
end

local function leafPosition(index: number): (number, number, number)
  return index % 16 * 4, index // 16 % 16 * 4, index % 7 * 0.5
end

local function addLeaf(world: World, cell: number, index: number): number
  local leaf = world:create(cell)
  world:setPosition(leaf, leafPosition(index))
  world:setBounds(leaf, -1, -1, -1, 1, 1, 1)

  if index % 4 == 0 then world:setRange(leaf, 0, 512) end

  return leaf
end

--- A flat world: a cell to every 64 nodes on a grid 128 apart, the rest leaves dealt round the
--- cells, each a unit box, one in four with a view range. Odd cells wear mask 1 and even ones 2.
local function flat(count: number, batched: boolean): Flat
  local world = scene.new(count)
  local cellCount = math.max(1, count // 64)
  local cells, leaves = table.create(cellCount), table.create(count - cellCount)

  if batched then world:beginBatch() end

  for index = 1, cellCount do
    local cell = world:create()
    cells[index] = cell
    world:setPosition(cell, cellPosition(index))
    world:setMask(cell, if index % 2 == 0 then 2 else 1)
  end

  for index = 1, count - cellCount do
    leaves[index] = addLeaf(world, cells[(index - 1) % cellCount + 1], index)
  end

  if batched then world:endBatch() end

  world:update()

  return { world = world, cells = cells, leaves = leaves }
end

--- A tree with `Fanout` children to a node, `depth` levels under its root: each level a quarter
--- the spacing of the one above, the last level unit boxes, the level above it view ranges.
--- Returns the scene and its nodes by level, the root's level first.
local function tree(depth: number): (World, { { number } })
  local world = scene.new(1024)
  local root = world:create()
  local levels = { { root } }
  local spacing = 4096

  world:beginBatch()

  for level = 1, depth do
    local above = levels[level]
    local nodes = table.create(#above * Fanout)
    spacing /= 4

    for index, parent in above do
      for child = 0, Fanout - 1 do
        local node = world:create(parent)
        nodes[(index - 1) * Fanout + child + 1] = node
        world:setPosition(node, (child % 3 - 1) * spacing, (child // 3 - 0.5) * spacing, level)

        if level == depth then world:setBounds(node, -1, -1, -1, 1, 1, 1) end
        if level == depth - 1 then world:setRange(node, 0, 2048) end
      end
    end

    levels[level + 1] = nodes
  end

  world:endBatch()
  world:update()

  return world, levels
end

for _, batched in { false, true } do
  local built: Flat
  local how = if batched then 'in a batch' else 'one at a time'

  timed(`build 20,000 nodes {how}`, function() built = flat(20000, batched) end, function(): string
    local world = built.world

    return `{listed(world:collect())}; {#world:queryAabb(0, 0, -10, 300, 300, 10)} in a box`
  end)
end

do
  local built: Flat

  timed('build 100,000 nodes in a batch', function() built = flat(100000, true) end, function(): string
    local world = built.world

    return `{listed(world:collect())}; {#world:queryAabb(0, 0, -10, 300, 300, 10)} in a box`
  end)
end

-- The flat world. Every workload here leaves it as it found it, so each answers alike whichever
-- others ran before it.
do
  local built = flat(100000, true)
  local world, cells, leaves = built.world, built.cells, built.leaves
  local everything = world:collect()
  local first: Counts, second: Counts = world:update(), world:update()
  local cursor = 0

  local function both(): string
    return `{placed(first)}; back, {placed(second)}`
  end

  timed('flat: update with nothing to do', function() first = world:update() end, function(): string
    return placed(first)
  end)

  timed('flat: move a leaf and back, an update after each', function()
    cursor = cursor % #leaves + 1
    local leaf = leaves[cursor]
    local column, row, level = leafPosition(cursor)
    world:setPosition(leaf, column + 0.5, row, level)
    first = world:update()
    world:setPosition(leaf, column, row, level)
    second = world:update()
  end, both)

  -- The first 32 cells were dealt one leaf more than the rest, so the cursor stays past them.
  timed('flat: move a cell of 64 and back, an update after each', function()
    cursor = math.max(32, cursor % #cells) + 1
    local cell = cells[cursor]
    local column, row, level = cellPosition(cursor)
    world:setPosition(cell, column + 0.5, row, level)
    first = world:update()
    world:setPosition(cell, column, row, level)
    second = world:update()
  end, both)

  timed('flat: move 1,000 leaves of 1,000 cells and back, an update after each', function()
    for step = 1, 1000 do
      local index = (step * 97 - 1) % #leaves + 1
      local column, row, level = leafPosition(index)
      world:setPosition(leaves[index], column + 0.5, row, level)
    end

    first = world:update()

    for step = 1, 1000 do
      local index = (step * 97 - 1) % #leaves + 1
      world:setPosition(leaves[index], leafPosition(index))
    end

    second = world:update()
  end, both)

  timed('flat: resize the boxes of 1,000 leaves and back, an update after each', function()
    for step = 1, 1000 do
      world:setBounds(leaves[(step * 97 - 1) % #leaves + 1], -2, -2, -2, 2, 2, 2)
    end

    first = world:update()

    for step = 1, 1000 do
      world:setBounds(leaves[(step * 97 - 1) % #leaves + 1], -1, -1, -1, 1, 1, 1)
    end

    second = world:update()
  end, both)

  timed('flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each', function()
    for step = 1, 10000 do
      world:setBounds(leaves[(step * 7 - 1) % #leaves + 1], -2, -2, -2, 2, 2, 2)
    end

    for step = 1, 100 do
      world:setBounds(cells[step * 13], -3, -3, -3, 3, 3, 3)
    end

    first = world:update()

    for step = 1, 10000 do
      world:setBounds(leaves[(step * 7 - 1) % #leaves + 1], -1, -1, -1, 1, 1, 1)
    end

    for step = 1, 100 do
      world:clearBounds(cells[step * 13])
    end

    second = world:update()
  end, both)

  timed('flat: move a leaf in a batch and realize all 100,000 nodes', function()
    world:beginBatch()
    world:setPosition(leaves[1], leafPosition(1))
    world:endBatch()
    first = world:update()
  end, function(): string
    return placed(first)
  end)

  walked('flat: collect every node', function(out: { number }) world:collect(Everything, out) end, everything)

  walked('flat: collect through a mask half the cells wear', function(out: { number }) world:collect(1, out) end)

  walked('flat: query a box around one cell', function(out: { number })
    world:queryAabb(128, 0, -10, 192, 64, 10, Everything, out)
  end)

  walked('flat: query a box around one cell, into a table that held every node', function(out: { number })
    world:queryAabb(128, 0, -10, 192, 64, 10, Everything, out)
  end, everything)

  walked('flat: query a box around a hundred cells', function(out: { number })
    world:queryAabb(1000, 500, -10, 2280, 1780, 10, Everything, out)
  end)

  walked('flat: query a box around the world', function(out: { number })
    world:queryAabb(-100000, -100000, -100000, 100000, 100000, 100000, Everything, out)
  end)

  walked('flat: collect for a view from a corner', function(out: { number })
    world:collectForView(0, 0, 0, Everything, out)
  end)

  walked('flat: collect for a view from the middle, through a mask', function(out: { number })
    world:collectForView(4096, 1600, 0, 2, out)
  end)
end

-- The tree: 55,987 nodes, 46,656 of them leaves six levels under the root's children.
do
  local world, levels = tree(6)
  local leaves = levels[7]
  local first: Counts, second: Counts = world:update(), world:update()

  local function both(): string
    return `{placed(first)}; back, {placed(second)}`
  end

  --- Puts 5 nodes three levels above the leaves, 50 two above, 150 one above and 295 leaves
  --- `amount` higher than the tree was built with.
  local function lift(amount: number)
    for level = 4, 7 do
      local nodes = levels[level]

      for step = 1, Moved[level] do
        local index = (step * 211 - 1) % #nodes + 1
        local child = (index - 1) % Fanout
        local spacing = 4096 / 4 ^ (level - 1)
        world:setPosition(nodes[index], (child % 3 - 1) * spacing, (child // 3 - 0.5) * spacing, level - 1 + amount)
      end
    end
  end

  timed('tree: move 500 nodes of four depths and back, an update after each', function()
    lift(0.5)
    first = world:update()
    lift(0)
    second = world:update()
  end, both)

  timed('tree: resize the boxes of 2,000 leaves and back, an update after each', function()
    for step = 1, 2000 do
      world:setBounds(leaves[(step * 23 - 1) % #leaves + 1], -2, -2, -2, 2, 2, 2)
    end

    first = world:update()

    for step = 1, 2000 do
      world:setBounds(leaves[(step * 23 - 1) % #leaves + 1], -1, -1, -1, 1, 1, 1)
    end

    second = world:update()
  end, both)

  walked('tree: collect every node', function(out: { number }) world:collect(Everything, out) end)

  walked('tree: query a box around one branch', function(out: { number })
    world:queryAabb(-1100, -600, -10, -900, -400, 30, Everything, out)
  end)

  walked('tree: collect for a view from beside the root', function(out: { number })
    world:collectForView(-1024, -512, 0, Everything, out)
  end)
end

-- A world whose shape the workloads change. What they answer is counts, which no order of slots
-- or of siblings alters.
do
  local built = flat(20000, true)
  local world, cells, leaves = built.world, built.cells, built.leaves
  local first: Counts, second: Counts = world:update(), world:update()
  local removed = 0

  local function census(): string
    local stats = world:stats()

    return `{stats.nodes} nodes, {stats.roots} roots, {stats.highWaterSlots} slots, {#world:collect()} collected`
  end

  timed('churn: create and destroy 1,000 leaves, then update', function()
    for step = 1, 1000 do
      world:destroy(world:create(cells[(step - 1) % #cells + 1]))
    end

    first = world:update()
  end, function(): string
    return `{placed(first)}; {census()}`
  end)

  timed('churn: move 1,000 leaves to other cells and back, an update after each', function()
    for step = 1, 1000 do
      world:setParent(leaves[step * 19], cells[step % #cells + 1])
    end

    first = world:update()

    for step = 1, 1000 do
      local index = step * 19
      world:setParent(leaves[index], cells[(index - 1) % #cells + 1])
    end

    second = world:update()
  end, function(): string
    return `{placed(first)}; back, {placed(second)}; {census()}`
  end)

  timed('churn: destroy 16 cells of 64 and build them again, then update', function()
    removed = 0

    for step = 1, 16 do
      removed += world:destroy(cells[step * 19])
    end

    for step = 1, 16 do
      local index = step * 19
      local cell = world:create()
      cells[index] = cell
      world:setPosition(cell, cellPosition(index))

      for leaf = index, #leaves, #cells do
        leaves[leaf] = addLeaf(world, cell, leaf)
      end
    end

    first = world:update()
  end, function(): string
    return `{removed} removed; {placed(first)}; {census()}`
  end)
end
