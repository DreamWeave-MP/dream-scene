# dream.scene 0.1.0 benchmarks

The move onto l3i 2.0, measured as an A/B with `bench/bench.jsl`. `PROFILE.md` is the older record, of the session that made the scene incremental; nothing in it was remeasured here.

## On l3i 2.0

Measured on 2026-10-12 on an Intel(R) Core(TM) i7-10870H CPU @ 2.20GHz (16 threads), with Jess 0.1.0 on l3i 2.0.2, a verified release build, by

```sh
jess run --package jpk/dream-scene --package-path jpk jpk/dream-scene/bench/bench.jsl
```

Base is commit `c7d9adb`: 0.1.0 as imported, with its suite, this bench, and one fix to the count of roots that `stats()` reports, which no workload times. Head is `1f40ca1`, the last commit to touch the source. Same binary, five rounds inside one hold of the machine's bench lock, base and head each once a round and the order turned every round; each figure is the median of the five, each of which is the bench's own median of seven batches. The last column is the ratio from a second hold, of three rounds, with glibc told neither to trim its heap nor to map large blocks apart (`MALLOC_TRIM_THRESHOLD_` and `MALLOC_MMAP_THRESHOLD_` at a gibibyte) on both sides: no row here is of two minds about its heap, and the two holds agree. Every workload checks what it answers against what 0.1.0 answers (what an update counts, how many handles a traversal lists and a digest of them in order), before its first batch and after its last, and base and head pass the same checks.

Other agents' suites were running on the machine throughout. Inside the hold two of the base's rows, the flat view collections, moved by 14 and 17 percent between rounds and no other row by more than 10; read a difference under 5 percent as none. The first two holds of this A/B, earlier the same evening, read the box around the world and the two flat view collections at 1.9 to 2.3 times, off a base a third slower on those rows than it has measured since; every hold since, nineteen rounds in all, has them where the table does.

Microseconds per call. A call is what the name says: one build, or the edits named and the update after them, twice over where the name says "and back", or one traversal.

| Workload | Base | Head | Base / head | Again |
| --- | ---: | ---: | ---: | ---: |
| build 20,000 nodes one at a time | 20,733.9 | 12,115.0 | 1.71 | 1.81 |
| build 20,000 nodes in a batch | 18,703.7 | 10,060.3 | 1.86 | 1.91 |
| build 100,000 nodes in a batch | 100,029.0 | 53,515.2 | 1.87 | 1.89 |
| flat: update with nothing to do | 0.112 | 0.094 | 1.19 | 1.15 |
| flat: move a leaf and back, an update after each | 107.3 | 3.228 | 33.3 | 34.4 |
| flat: move a cell of 64 and back, an update after each | 130.9 | 19.08 | 6.86 | 6.97 |
| flat: move 1,000 leaves of 1,000 cells and back, an update after each | 5,303.9 | 3,756.0 | 1.41 | 1.45 |
| flat: resize the boxes of 1,000 leaves and back, an update after each | 6,111.0 | 3,621.5 | 1.69 | 1.74 |
| flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each | 25,511.9 | 9,108.4 | 2.80 | 2.81 |
| flat: move a leaf in a batch and realize all 100,000 nodes | 21,586.4 | 15,172.0 | 1.42 | 1.46 |
| flat: collect every node | 5,341.9 | 2,459.9 | 2.17 | 2.19 |
| flat: collect through a mask half the cells wear | 2,779.8 | 1,310.7 | 2.12 | 2.25 |
| flat: query a box around one cell | 46.10 | 38.70 | 1.19 | 1.17 |
| flat: query a box around one cell, into a table that held every node | 96.28 | 89.97 | 1.07 | 1.11 |
| flat: query a box around a hundred cells | 539.2 | 335.1 | 1.61 | 1.64 |
| flat: query a box around the world | 7,869.5 | 4,651.6 | 1.69 | 1.70 |
| flat: collect for a view from a corner | 7,388.9 | 4,123.1 | 1.79 | 1.75 |
| flat: collect for a view from the middle, through a mask | 3,446.6 | 2,176.7 | 1.58 | 1.57 |
| tree: move 500 nodes of four depths and back, an update after each | 2,973.9 | 1,592.8 | 1.87 | 1.85 |
| tree: resize the boxes of 2,000 leaves and back, an update after each | 8,897.6 | 2,069.6 | 4.30 | 4.32 |
| tree: collect every node | 2,894.1 | 1,241.6 | 2.33 | 2.35 |
| tree: query a box around one branch | 64.12 | 34.74 | 1.85 | 1.76 |
| tree: collect for a view from beside the root | 3,264.5 | 1,599.7 | 2.04 | 2.01 |
| churn: create and destroy 1,000 leaves, then update | 13,700.4 | 628.5 | 21.8 | 21.7 |
| churn: move 1,000 leaves to other cells and back, an update after each | 2,454.0 | 1,679.2 | 1.46 | 1.45 |
| churn: destroy 16 cells of 64 and build them again, then update | 1,288.4 | 609.1 | 2.12 | 2.16 |

The flat world is 100,000 nodes: 1,562 cells on a grid, the rest unit boxes dealt round them, one in four with a view range. The tree is 55,987 nodes, six children to a node, seven levels. The churn world is the flat one at 20,000 nodes.

The module itself loads in 10.6 ms where it took 11.4 ms (the median of fifteen fresh processes each, turn about, `require` timed from inside): the dialect's prelude costs it nothing that the smaller method table does not give back.

### What moved, and what moved it

Most of this is not the dialect. A scene is a tree of linked slots in buffers, walked a node at a time, and a comprehension has nothing to say about a pointer chase. What l3i 2.0 gave it directly is one thing: the order in which an update folds the bounds it has left. The rest came from looking at where the time was, which the bench made possible, and is ordinary work.

Each commit as a ratio of `9f29b16` to it: the base with its names and layout brought to the house style and nothing else, which measures as the base does (0.93 to 1.03 of it, from one hold to another). Three rounds, a hold of the lock to each, the commits in a different order every round.

| Workload | `9b4ce7c` lengths | `02eee7d` argsort | `ddbc17a` buffers once | `f3a2b98` setters | `1e8f3f8` straight link | `0f90cd0` leaf boxes | `9211cd9` local calls | `b174fe7` one pass |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| build 20,000 nodes one at a time | 1.04 | 1.04 | 1.10 | 1.14 | 1.47 | 1.54 | 1.89 | 1.89 |
| build 20,000 nodes in a batch | 0.98 | 0.98 | 1.01 | 1.08 | 1.44 | 1.46 | 1.88 | 1.89 |
| build 100,000 nodes in a batch | 0.96 | 0.97 | 1.03 | 1.08 | 1.41 | 1.49 | 1.87 | 1.86 |
| flat: update with nothing to do | 1.14 | 1.11 | 1.20 | 1.18 | 1.20 | 1.22 | 1.20 | 1.19 |
| flat: move a leaf and back, an update after each | 26.8 | 26.5 | 31.7 | 32.2 | 32.1 | 33.2 | 33.3 | 32.4 |
| flat: move a cell of 64 and back, an update after each | 4.78 | 4.49 | 5.91 | 5.98 | 6.00 | 6.90 | 6.97 | 6.88 |
| flat: move 1,000 leaves of 1,000 cells and back, an update after each | 0.98 | 1.18 | 1.33 | 1.33 | 1.32 | 1.40 | 1.39 | 1.36 |
| flat: resize the boxes of 1,000 leaves and back, an update after each | 0.97 | 1.41 | 1.63 | 1.63 | 1.58 | 1.68 | 1.67 | 1.65 |
| flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each | 0.97 | 2.10 | 2.53 | 2.54 | 2.51 | 2.57 | 2.75 | 2.75 |
| flat: move a leaf in a batch and realize all 100,000 nodes | 1.00 | 0.97 | 1.35 | 1.31 | 1.31 | 1.51 | 1.47 | 1.50 |
| flat: collect every node | 1.03 | 1.05 | 2.22 | 2.17 | 2.19 | 2.21 | 2.14 | 2.15 |
| flat: collect through a mask half the cells wear | 1.02 | 1.02 | 2.15 | 2.07 | 2.13 | 2.14 | 2.09 | 2.10 |
| flat: query a box around one cell | 1.04 | 1.06 | 1.28 | 1.27 | 1.29 | 1.28 | 1.28 | 1.28 |
| flat: query a box around one cell, into a table that held every node | 0.97 | 0.99 | 1.09 | 1.08 | 1.06 | 1.11 | 1.07 | 1.09 |
| flat: query a box around a hundred cells | 0.99 | 1.00 | 1.67 | 1.65 | 1.66 | 1.66 | 1.65 | 1.65 |
| flat: query a box around the world | 1.00 | 1.01 | 1.79 | 1.76 | 1.76 | 1.77 | 1.71 | 1.74 |
| flat: collect for a view from a corner | 0.99 | 1.03 | 1.78 | 1.78 | 1.78 | 1.78 | 1.76 | 1.74 |
| flat: collect for a view from the middle, through a mask | 0.97 | 1.01 | 1.56 | 1.53 | 1.52 | 1.59 | 1.52 | 1.53 |
| tree: move 500 nodes of four depths and back, an update after each | 1.04 | 1.27 | 1.63 | 1.65 | 1.64 | 1.81 | 1.85 | 1.86 |
| tree: resize the boxes of 2,000 leaves and back, an update after each | 1.01 | 3.03 | 3.76 | 3.91 | 3.94 | 3.93 | 4.35 | 4.34 |
| tree: collect every node | 1.03 | 1.02 | 2.44 | 2.46 | 2.47 | 2.46 | 2.44 | 2.43 |
| tree: query a box around one branch | 1.03 | 1.01 | 1.82 | 1.80 | 1.84 | 1.85 | 1.81 | 1.81 |
| tree: collect for a view from beside the root | 0.96 | 0.98 | 1.98 | 1.96 | 1.97 | 1.96 | 1.97 | 1.96 |
| churn: create and destroy 1,000 leaves, then update | 11.8 | 13.1 | 14.7 | 15.1 | 19.0 | 19.5 | 21.2 | 21.3 |
| churn: move 1,000 leaves to other cells and back, an update after each | 1.02 | 1.12 | 1.27 | 1.30 | 1.31 | 1.36 | 1.46 | 1.47 |
| churn: destroy 16 cells of 64 and build them again, then update | 1.25 | 1.24 | 1.32 | 1.37 | 1.71 | 1.84 | 2.16 | 2.18 |

- **`51f020a` and `9f29b16`, the house style.** Names, layout, quotes, and `Scene.new` typed as what it returns. No change, as it should be: the scene after them is what every column above is a ratio of.
- **`9b4ce7c`, lengths kept beside the scratch lists.** Every update, destroy and traversal cleared its scratch tables with `table.clear`, which clears a table's whole capacity, and the capacity was whatever the biggest scene had needed: an update that moved one leaf of 100,000 nodes spent about 52 of its 54 microseconds zeroing scratch it was about to write a slot or two of. Each list now carries a count and nothing is cleared. That is the 27 times on one leaf, the 5 on one cell, the 12 on create and destroy. It has nothing to do with l3i 2.0.
- **`02eee7d`, the data plane.** The bounds an update has left to fold after the transforms, the ancestors of what changed and every bounds-only edit, are folded deepest first. That was `table.sort` with a comparator that read two depths out of a buffer on every comparison. Now a buffer sink collects the slots (`into(remaining, 'u32')[for slot in dirtyBounds[1:count] if ... => slot]`), `data.gather` reads their depths out of the node records in one call (`'u32@32+28'`, the depth field as a strided layout), and `data.argsort` orders them; nodes of one depth read nothing of each other, so a stable sort by depth alone is all the order there is. 1.45 times on a thousand resized boxes, 2.2 on ten thousand, 3.0 on the tree, where the list is long and of many depths, and 1.1 to 1.2 on the updates that move a thousand nodes. This is the one row-moving change that is l3i 2.0's. One row reads 6 percent the other way at this commit, the cell of 64, as it did when the commit was first measured; nothing in the commit is on that row's path but one pass of the sink over a list of one, and the next commit takes the row a third faster.
- **`ddbc17a`, each buffer read out of the scene once.** An update or a traversal read `self._meta` and its neighbours again for every field of every node, and called a method for each handle it listed and each box it placed or folded. The buffers are now taken out once, by a record pattern, and the per-node work is local functions over them. 1.1 to 2.4 times on the traversals, 6 to 39 percent on the updates. The pattern is the dialect; the speed is the hoist, which a line of `local` each would have bought as well.
- **`f3a2b98`, the same hoist in the setters.** 4 to 7 percent on the builds, which is the edge of what these rounds can tell, and nothing elsewhere.
- **`1e8f3f8`, a node linked where it is made.** `create(parent)` linked the node among the roots, then moved it with everything `setParent` checks. Under a live parent it is now linked there directly, which leaves every list as it was left before; any other parent still goes to `setParent`, to be refused in its words. 1.3 times on the builds, and 1.25 on the churn that makes nodes.
- **`0f90cd0`, a leaf's subtree box written with its own.** A node with no children waited for the fold to copy its box to its subtree box. It is written as the transform is placed, from the same numbers, which the buffer rounds alike. 11 to 16 percent where whole subtrees move.
- **`9211cd9`, bookkeeping as local functions.** `_queueBounds`, `_markTransform`, `_link` and the rest were methods found through the metatable on every call; they are local functions now. 1.23 to 1.29 times on the builds again, and 7 to 18 percent on the larger bounds-only updates and the churn. `_slot`, which refuses a bad handle, stays a method: its error is laid on the caller of the operation by counting frames, and a local function the compiler may inline would count one fewer.
- **`b174fe7`**, a destroy that frees in its one pass, measured no change and is there for the reading.
- **`1f40ca1`, a fix, not a speedup.** The straight link looked the parent up before the node was among the roots, so a parent that raised on the way to a slot (a number that is not finite, or no number at all) left the node alive outside the tree, where 0.1.0 left it a root, and one that fell between two handles went without what `setParent` says of it. Only a whole number is looked up there now. In the five rounds above, beside the source as it stood before: 0.96 to 1.02 on every row, the builds among them, which is no change.

### Tried, and left out

None of this is in the package, and none of it was measured again with the tables above: these are the readings taken when it was tried.

- **The traversal stack as a `u32` buffer.** Nothing on the traversals (0.90 to 1.09 over five rounds, a row's own noise), perhaps 7 percent on three update rows over seven rounds, and an update can need a stack longer than the scene has slots, because a slot made, destroyed and made again between updates is queued once for each making. Not worth the bound.
- **The parent's matrix kept across a run of siblings**, so that 64 leaves read their cell's matrix once: 1.00 to 1.04 over seven rounds. Left out.
- **The handle check inline in every operation**, with the method called only to refuse: 1.00 to 1.08 on nine rows over four rounds, none of them the wrong side of 1.00 and none clear of the noise. Left out, for two lines in fourteen places.
- **Child boxes reduced by the data plane.** A fold is a `min` and a `max` over a node's children on six fields, which is what `data.min` is for, but the children are a linked list, not a span: it would take a walk to list them and twelve calls to gather and reduce them, against under 2 microseconds for 64 children in the loop, and `data.min` keeps a leading NaN where the loop's `math.min` drops it. Not tried past the arithmetic.

### What it still costs

- **A reused `out` table is cleared whole.** `collect`, `queryAabb` and `collectForView` promise the table they are handed holds the answer and nothing else, so they `table.clear` it, and that costs its capacity, not its length: the query that finds 64 handles takes 39 microseconds into a table of its own and 90 into one that once held all 100,000. Keep a table for each size of question.
- **A query walks every root.** The 39 microseconds are 1,562 cells tested one by one; the hierarchy only prunes below a root. A flat world wants its cells under a few parents, or the spatial index `DESIGN.md` leaves to another package.
- **A fold reads every child.** One leaf resized folds its parent over all its siblings, which is most of what a bounds-only update costs.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.16 and 1.43 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@dream/scene`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@dream/scene` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.054 s | 0.047 s |
| Final | 0.052 s | 0.051 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| build 20,000 nodes one at a time | 14.61 | **4.954×** | 14.66 | 1.003× |
| build 20,000 nodes in a batch | 12.67 | **4.805×** | 13.60 | **1.073×** |
| build 100,000 nodes in a batch | 66.60 | **4.741×** | 69.97 | **1.051×** |
| flat: update with nothing to do | 0.00012 | **1.197×** | 0.00012 | 1.034× |
| flat: move a leaf and back, an update after each | 0.00337 | **7.894×** | 0.00340 | 1.010× |
| flat: move a cell of 64 and back, an update after each | 0.01891 | **10.608×** | 0.01977 | 1.045× |
| flat: move 1,000 leaves of 1,000 cells and back, an update after each | 3.823 | **7.048×** | 3.778 | 0.988× |
| flat: resize the boxes of 1,000 leaves and back, an update after each | 3.653 | **7.050×** | 3.605 | 0.987× |
| flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each | 10.34 | **6.913×** | 10.01 | 0.968× |
| flat: move a leaf in a batch and realize all 100,000 nodes | 14.97 | **10.586×** | 14.61 | 0.976× |
| flat: collect every node | 2.420 | **4.993×** | 2.374 | 0.981× |
| flat: collect through a mask half the cells wear | 1.329 | **4.773×** | 1.294 | 0.974× |
| flat: query a box around one cell | 0.03865 | **7.488×** | 0.03842 | 0.994× |
| flat: query a box around one cell, into a table that held every node | 0.08730 | **3.862×** | 0.08647 | 0.990× |
| flat: query a box around a hundred cells | 0.3277 | **8.066×** | 0.3189 | 0.973× |
| flat: query a box around the world | 4.564 | **8.015×** | 4.634 | 1.015× |
| flat: collect for a view from a corner | 4.101 | **6.276×** | 3.988 | 0.972× |
| flat: collect for a view from the middle, through a mask | 2.154 | **6.350×** | 2.102 | 0.976× |
| tree: move 500 nodes of four depths and back, an update after each | 1.691 | **10.668×** | 1.667 | 0.986× |
| tree: resize the boxes of 2,000 leaves and back, an update after each | 2.210 | **7.201×** | 2.255 | 1.021× |
| tree: collect every node | 1.218 | **5.734×** | 1.199 | 0.984× |
| tree: query a box around one branch | 0.03479 | **9.353×** | 0.03522 | 1.012× |
| tree: collect for a view from beside the root | 1.568 | **7.117×** | 1.599 | 1.020× |
| churn: create and destroy 1,000 leaves, then update | 0.6943 | **7.130×** | 0.8765 | **1.262×** |
| churn: move 1,000 leaves to other cells and back, an update after each | 1.736 | **7.364×** | 2.412 | **1.389×** |
| churn: destroy 16 cells of 64 and build them again, then update | 0.7300 | **5.472×** | 0.7537 | 1.032× |

What carries the directive: `scene`, whole, the package's only module, as before this pass.

Marking only the functions the rows' profiles named (the bounds and transform propagation, the
cell bookkeeping, `update`, `collect`, and the queries) saved 1.4 ms a load and left the churn
rows 1.26x and 1.39x slower than all marked: creating and destroying 1,000 leaves and moving them
between cells, each followed by an update. A scene does that every frame and loads once, so the
module stays marked whole. The table's final column is that function-marked session, kept as the
record of what was tried; the package ships as all marked.
