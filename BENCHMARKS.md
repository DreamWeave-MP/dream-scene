# dream.scene 0.1.0 benchmarks

The move onto l3i 2.0, measured as an A/B with `bench/bench.luau`. `PROFILE.md` is the older record, of the session that made the scene incremental; nothing in it was remeasured here.

## On l3i 2.0

Measured on 2026-10-12, in the run started on 2026-10-11, on an Intel(R) Core(TM) i7-10870H CPU @ 2.20GHz (16 threads), with Jess 0.1.0 on l3i 2.0.2, a verified release build, by

```sh
jess run --package jpk/dream-scene --package-path jpk jpk/dream-scene/bench/bench.luau
```

Base is commit `c7d9adb`: 0.1.0 as imported, with its suite, this bench, and one fix to the count of roots that `stats()` reports, which no workload times. Head is `b174fe7`, the last commit to touch the source. Same binary, three rounds inside one hold of the machine's bench lock, base first in the odd rounds and head first in the even one; each figure is the median of the three, each of which is the bench's own median of seven batches. The last column is the ratio from a second hold of three rounds, half an hour later. Every workload checks what it answers against what 0.1.0 answers (what an update counts, how many handles a traversal lists and a digest of them in order), before its first batch and after its last, and base and head pass the same checks.

Other agents' suites were running on the machine throughout. The rows that fill a table of 100,000 handles moved by as much as 15 percent between rounds on both sides; read a difference under 5 percent as none.

Microseconds per call. A call is what the name says: one build, or the edits named and the update after them, twice over where the name says "and back", or one traversal.

| Workload | Base | Head | Base / head | Again |
| --- | ---: | ---: | ---: | ---: |
| build 20,000 nodes one at a time | 23,018.1 | 12,659.5 | 1.82 | 1.76 |
| build 20,000 nodes in a batch | 20,875.1 | 10,614.4 | 1.97 | 1.78 |
| build 100,000 nodes in a batch | 107,370.6 | 61,428.4 | 1.75 | 1.80 |
| flat: update with nothing to do | 0.120 | 0.098 | 1.22 | 1.18 |
| flat: move a leaf and back, an update after each | 117.7 | 3.453 | 34.1 | 29.0 |
| flat: move a cell of 64 and back, an update after each | 142.5 | 20.30 | 7.02 | 6.76 |
| flat: move 1,000 leaves of 1,000 cells and back, an update after each | 6,015.3 | 3,913.6 | 1.54 | 1.44 |
| flat: resize the boxes of 1,000 leaves and back, an update after each | 6,582.3 | 3,899.2 | 1.69 | 1.75 |
| flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each | 28,842.5 | 9,883.5 | 2.92 | 2.75 |
| flat: move a leaf in a batch and realize all 100,000 nodes | 23,738.7 | 16,148.6 | 1.47 | 1.44 |
| flat: collect every node | 5,492.3 | 2,581.6 | 2.13 | 2.18 |
| flat: collect through a mask half the cells wear | 2,858.5 | 1,324.5 | 2.16 | 1.99 |
| flat: query a box around one cell | 49.32 | 41.30 | 1.19 | 1.21 |
| flat: query a box around one cell, into a table that held every node | 103.6 | 92.55 | 1.12 | 1.07 |
| flat: query a box around a hundred cells | 588.5 | 352.2 | 1.67 | 1.72 |
| flat: query a box around the world | 10,518.9 | 5,200.8 | 2.02 | 2.01 |
| flat: collect for a view from a corner | 9,882.7 | 4,387.5 | 2.25 | 2.07 |
| flat: collect for a view from the middle, through a mask | 4,956.3 | 2,370.8 | 2.09 | 1.86 |
| tree: move 500 nodes of four depths and back, an update after each | 3,395.9 | 1,745.3 | 1.95 | 1.87 |
| tree: resize the boxes of 2,000 leaves and back, an update after each | 10,332.9 | 2,259.3 | 4.57 | 4.47 |
| tree: collect every node | 3,011.4 | 1,330.9 | 2.26 | 2.51 |
| tree: query a box around one branch | 69.85 | 38.14 | 1.83 | 1.88 |
| tree: collect for a view from beside the root | 3,573.2 | 1,746.1 | 2.05 | 2.12 |
| churn: create and destroy 1,000 leaves, then update | 15,450.1 | 676.0 | 22.9 | 23.7 |
| churn: move 1,000 leaves to other cells and back, an update after each | 2,607.4 | 1,789.5 | 1.46 | 1.47 |
| churn: destroy 16 cells of 64 and build them again, then update | 1,366.9 | 657.3 | 2.08 | 2.23 |

The flat world is 100,000 nodes: 1,562 cells on a grid, the rest unit boxes dealt round them, one in four with a view range. The tree is 55,987 nodes, six children to a node, seven levels. The churn world is the flat one at 20,000 nodes.

The module itself loads in 11.1 ms where it took 12.0 ms (the median of fifteen fresh processes each, `require` timed from inside): the dialect's prelude costs it nothing that the smaller method table does not give back.

### What moved, and what moved it

Most of this is not the dialect. A scene is a tree of linked slots in buffers, walked a node at a time, and a comprehension has nothing to say about a pointer chase. What l3i 2.0 gave it directly is one thing: the order in which an update folds the bounds it has left. The rest came from looking at where the time was, which the bench made possible, and is ordinary work.

Each commit against the same base, as a ratio of base to that commit. Two sets of holds, three rounds each, so the two halves have their own reading of the base and of `ddbc17a`, and differ between themselves by the noise above.

| Workload | `51f020a` style | `9b4ce7c` lengths | `02eee7d` argsort | `ddbc17a` buffers once |
| --- | ---: | ---: | ---: | ---: |
| build 20,000 nodes one at a time | 0.99 | 0.99 | 0.98 | 1.04 |
| build 20,000 nodes in a batch | 0.99 | 0.98 | 0.97 | 1.00 |
| build 100,000 nodes in a batch | 0.97 | 1.01 | 1.00 | 1.04 |
| flat: update with nothing to do | 1.00 | 1.15 | 1.17 | 1.20 |
| flat: move a leaf and back, an update after each | 1.03 | 26.2 | 26.9 | 31.0 |
| flat: move a cell of 64 and back, an update after each | 1.00 | 4.97 | 4.55 | 5.85 |
| flat: move 1,000 leaves of 1,000 cells and back, an update after each | 1.05 | 1.09 | 1.18 | 1.34 |
| flat: resize the boxes of 1,000 leaves and back, an update after each | 0.99 | 0.98 | 1.32 | 1.53 |
| flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each | 1.00 | 0.94 | 2.15 | 2.36 |
| flat: move a leaf in a batch and realize all 100,000 nodes | 1.05 | 1.00 | 0.87 | 1.20 |
| flat: collect every node | 1.02 | 0.99 | 0.98 | 2.02 |
| flat: collect through a mask half the cells wear | 1.04 | 1.06 | 1.02 | 1.98 |
| flat: query a box around one cell | 1.02 | 1.04 | 1.04 | 1.19 |
| flat: query a box around one cell, into a table that held every node | 1.00 | 1.02 | 1.02 | 1.10 |
| flat: query a box around a hundred cells | 1.05 | 1.02 | 1.06 | 1.62 |
| flat: query a box around the world | 1.11 | 1.07 | 1.11 | 1.30 |
| flat: collect for a view from a corner | 1.04 | 1.03 | 1.00 | 1.36 |
| flat: collect for a view from the middle, through a mask | 1.04 | 1.01 | 1.00 | 1.35 |
| tree: move 500 nodes of four depths and back, an update after each | 0.99 | 1.05 | 1.26 | 1.61 |
| tree: resize the boxes of 2,000 leaves and back, an update after each | 1.03 | 1.04 | 3.02 | 3.66 |
| tree: collect every node | 1.00 | 1.03 | 1.02 | 2.29 |
| tree: query a box around one branch | 1.02 | 1.02 | 0.99 | 1.67 |
| tree: collect for a view from beside the root | 1.06 | 1.07 | 1.01 | 1.97 |
| churn: create and destroy 1,000 leaves, then update | 1.02 | 12.5 | 13.6 | 14.7 |
| churn: move 1,000 leaves to other cells and back, an update after each | 0.99 | 1.03 | 1.12 | 1.28 |
| churn: destroy 16 cells of 64 and build them again, then update | 0.99 | 1.22 | 1.23 | 1.30 |

| Workload | `ddbc17a` buffers once | `1e8f3f8` straight link | `0f90cd0` leaf boxes | `9211cd9` local calls | `b174fe7` head |
| --- | ---: | ---: | ---: | ---: | ---: |
| build 20,000 nodes one at a time | 1.00 | 1.40 | 1.41 | 1.81 | 1.84 |
| build 20,000 nodes in a batch | 0.99 | 1.42 | 1.41 | 1.85 | 1.88 |
| build 100,000 nodes in a batch | 1.03 | 1.45 | 1.47 | 1.90 | 1.93 |
| flat: update with nothing to do | 1.18 | 1.21 | 1.18 | 1.16 | 1.21 |
| flat: move a leaf and back, an update after each | 31.7 | 31.9 | 32.7 | 33.7 | 33.2 |
| flat: move a cell of 64 and back, an update after each | 6.09 | 6.18 | 7.06 | 7.20 | 7.15 |
| flat: move 1,000 leaves of 1,000 cells and back, an update after each | 1.44 | 1.46 | 1.39 | 1.46 | 1.50 |
| flat: resize the boxes of 1,000 leaves and back, an update after each | 1.72 | 1.73 | 1.71 | 1.74 | 1.79 |
| flat: resize the boxes of 10,000 leaves and of 100 cells, and back, an update after each | 2.48 | 2.62 | 2.40 | 2.78 | 2.82 |
| flat: move a leaf in a batch and realize all 100,000 nodes | 1.32 | 1.32 | 1.41 | 1.46 | 1.47 |
| flat: collect every node | 2.23 | 2.30 | 2.22 | 2.27 | 2.23 |
| flat: collect through a mask half the cells wear | 2.08 | 2.09 | 2.09 | 2.05 | 2.07 |
| flat: query a box around one cell | 1.18 | 1.19 | 1.17 | 1.19 | 1.18 |
| flat: query a box around one cell, into a table that held every node | 1.07 | 1.08 | 1.08 | 1.08 | 1.12 |
| flat: query a box around a hundred cells | 1.61 | 1.62 | 1.64 | 1.66 | 1.61 |
| flat: query a box around the world | 1.74 | 1.76 | 1.72 | 1.79 | 1.67 |
| flat: collect for a view from a corner | 1.69 | 1.75 | 1.65 | 1.73 | 1.69 |
| flat: collect for a view from the middle, through a mask | 1.55 | 1.61 | 1.58 | 1.53 | 1.55 |
| tree: move 500 nodes of four depths and back, an update after each | 1.55 | 1.53 | 1.70 | 1.78 | 1.75 |
| tree: resize the boxes of 2,000 leaves and back, an update after each | 3.66 | 3.72 | 3.67 | 4.17 | 4.16 |
| tree: collect every node | 2.35 | 2.36 | 2.32 | 2.39 | 2.34 |
| tree: query a box around one branch | 1.67 | 1.60 | 1.61 | 1.71 | 1.66 |
| tree: collect for a view from beside the root | 1.89 | 1.86 | 1.82 | 1.88 | 1.87 |
| churn: create and destroy 1,000 leaves, then update | 14.7 | 18.4 | 18.3 | 21.0 | 21.1 |
| churn: move 1,000 leaves to other cells and back, an update after each | 1.25 | 1.26 | 1.27 | 1.44 | 1.42 |
| churn: destroy 16 cells of 64 and build them again, then update | 1.33 | 1.72 | 1.76 | 2.18 | 2.16 |

- **`51f020a`, the house style.** Names, layout, quotes, and `Scene.new` typed as what it returns. No change, as it should be.
- **`9b4ce7c`, lengths kept beside the scratch lists.** Every update, destroy and traversal cleared its scratch tables with `table.clear`, which clears a table's whole capacity, and the capacity was whatever the biggest scene had needed: an update that moved one leaf of 100,000 nodes spent about 57 of its 59 microseconds zeroing scratch it was about to write a slot or two of. Each list now carries a count and nothing is cleared. That is the 26 times on one leaf, the 5 on one cell, the 12.5 on create and destroy. It has nothing to do with l3i 2.0.
- **`02eee7d`, the data plane.** The bounds an update has left to fold after the transforms, the ancestors of what changed and every bounds-only edit, are folded deepest first. That was `table.sort` with a comparator that read two depths out of a buffer on every comparison. Now a buffer sink collects the slots (`into(remaining, 'u32')[for slot in dirtyBounds[1:count] if ... => slot]`), `data.gather` reads their depths out of the node records in one call (`'u32@32+28'`, the depth field as a strided layout), and `data.argsort` orders them; nodes of one depth read nothing of each other, so a stable sort by depth alone is all the order there is. 1.35 times on a thousand resized boxes, 2.3 on ten thousand, 2.9 on the tree, where the list is long and of many depths. This is the one row-moving change that is l3i 2.0's.
- **`ddbc17a`, each buffer read out of the scene once.** An update or a traversal read `self._meta` and its neighbours again for every field of every node, and called a method for each handle it listed and each box it placed or folded. The buffers are now taken out once, by a record pattern, and the per-node work is local functions over them. 1.2 to 2.3 times on the traversals, 15 to 30 percent on the updates. The pattern is the dialect; the speed is the hoist, which a line of `local` each would have bought as well.
- **`1e8f3f8`, a node linked where it is made.** `create(parent)` linked the node among the roots, then moved it with everything `setParent` checks. Under a live parent it is now linked there directly, which leaves every list as it was left before; any other parent still goes to `setParent`, to be refused in its words. 1.4 times on the builds.
- **`0f90cd0`, a leaf's subtree box written with its own.** A node with no children waited for the fold to copy its box to its subtree box. It is written as the transform is placed, from the same numbers, which the buffer rounds alike. 7 to 14 percent where whole subtrees move.
- **`9211cd9`, bookkeeping as local functions.** `_queueBounds`, `_markTransform`, `_link` and the rest were methods found through the metatable on every call; they are local functions now. 1.3 times on the builds again, and 13 to 24 percent on the larger bounds-only updates and the churn. `_slot`, which refuses a bad handle, stays a method: its error is laid on the caller of the operation by counting frames, and a local function the compiler may inline would count one fewer.
- **`f3a2b98` and `b174fe7`**, the same hoist in the setters and a destroy that frees in its one pass, measured no change and are there for the reading.

### Tried, and left out

- **The traversal stack as a `u32` buffer.** Nothing on the traversals (0.90 to 1.09 over five rounds, a row's own noise), perhaps 7 percent on three update rows over seven rounds, and an update can need a stack longer than the scene has slots, because a slot made, destroyed and made again between updates is queued once for each making. Not worth the bound.
- **The parent's matrix kept across a run of siblings**, so that 64 leaves read their cell's matrix once: 1.00 to 1.04 over seven rounds. Left out.
- **The handle check inline in every operation**, with the method called only to refuse: 1.00 to 1.08 on nine rows over four rounds, none of them the wrong side of 1.00 and none clear of the noise. Left out, for two lines in fourteen places.
- **Child boxes reduced by the data plane.** A fold is a `min` and a `max` over a node's children on six fields, which is what `data.min` is for, but the children are a linked list, not a span: it would take a walk to list them and twelve calls to gather and reduce them, against under 2 microseconds for 64 children in the loop, and `data.min` keeps a leading NaN where the loop's `math.min` drops it. Not tried past the arithmetic.

### What it still costs

- **A reused `out` table is cleared whole.** `collect`, `queryAabb` and `collectForView` promise the table they are handed holds the answer and nothing else, so they `table.clear` it, and that costs its capacity, not its length: the query that finds 64 handles takes 41 microseconds into a table of its own and 93 into one that once held all 100,000. Keep a table for each size of question.
- **A query walks every root.** The 41 microseconds are 1,562 cells tested one by one; the hierarchy only prunes below a root. A flat world wants its cells under a few parents, or the spatial index `DESIGN.md` leaves to another package.
- **A fold reads every child.** One leaf resized folds its parent over all its siblings, which is most of what a bounds-only update costs.
