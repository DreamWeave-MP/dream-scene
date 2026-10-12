# L3i Cross-JPK Primitive Optimization Handoff

## Mission

We now have a growing ecosystem of serious JPKs implementing systems that would conventionally live in C, C++, or Rust: scene/world presentation, navigation, physics, parsers and structured-data handling, archive/file-format tooling, networking/HTTP, compression experiments, image/tooling workloads, reverse-engineering infrastructure, and increasingly complete game runtimes such as Doom and TES/OpenMW-oriented components.

The experiment is working.

The next task is **not** to move those systems back into Rust.

The task is to use the entire extant JPK ecosystem as a coordinated profiling corpus and determine whether a **small set of generic L3i/Luau primitives** can accelerate many packages simultaneously.

The desired feedback loop is:

```text
serious subsystem implemented in Luau
        ↓
profile representative real workload
        ↓
identify pathological inner operation
        ↓
find equivalent patterns in other JPKs
        ↓
design narrow reusable L3i primitive
        ↓
lower/package uses it
        ↓
benchmark entire ecosystem
        ↓
keep only primitives with demonstrated wins
```

The end state should be a **smaller, more powerful substrate**, not a giant collection of privileged engine APIs.

Do not invent native concepts corresponding to individual JPK abstractions unless exhaustive profiling proves that a generic primitive cannot solve the problem.

In particular:

> Do not add a native scene graph because `dream.scene` is hot.

> Do not add a native ESM parser because ESM decoding is hot.

> Do not add a native navmesh because Recast-derived workloads are hot.

> Do not add native physics objects because the physics JPK is hot.

Find the common operations underneath them.

---

# Ground rules

## Luau remains the systems layer

Our working hypothesis is that surprisingly large amounts of conventional engine/runtime systems code can remain in Luau if L3i gives Luau excellent access to a few critical low-level operations.

Every proposed primitive therefore starts guilty until proven innocent.

Ask:

1. What exact profile hotspot motivates it?
2. Can ordinary optimized Luau already solve it?
3. Can representation/algorithm changes solve it first?
4. Does the primitive remove allocation, interpretation, bounds-checking, dispatch, copying, or repeated scalar work?
5. Can at least two materially different JPK workloads use it?
6. Is it general enough that an unknown future JPK could plausibly use it?
7. Can the compiler lower a recognizable Luau idiom instead of exposing another bespoke API?
8. What are its semantics around aliasing, overflow, bounds, alignment, and malformed input?
9. How much faster is the complete consumer workload—not merely a synthetic microbenchmark?

Prefer primitives that answer several packages at once.

---

# Treat representation changes before native calls

The `dream.scene` experiment is the canonical example.

The naïve scene implementation rebuilt every bound every update.

At 100,000 nodes:

| Workload | Naïve | Optimized |
| --- | ---: | ---: |
| Idle update | ~17.391 ms | ~0.000406 ms |
| Dirty ~64-node subtree | ~16.061 ms | ~0.0844 ms |
| Batch build + realization | ~111.894 ms | ~100.855 ms |
| Collect all nodes | ~7.174 ms | ~6.847 ms |
| Tiny hierarchical AABB query | ~0.152 ms | ~0.0910 ms |
| Whole-world AABB query | ~10.442 ms | ~9.045 ms |

The ~42,800× idle improvement and ~190× localized update improvement came primarily from changing the algorithm to maintain dirty transform roots and affected bounds ancestors.

**No native primitive was required.**

This distinction is crucial.

Do not use native functionality to rescue a poor algorithm.

Only after the Luau implementation has the right asymptotic behavior should we inspect its remaining constant-factor costs.

---

# Corpus

Before implementing anything, inventory every current JPK and build a benchmark matrix.

Known areas currently worth including include at least:

- `dream.scene`
- the current Recast/navigation work
- the 2D physics JPK
- HTTP/networking test/package work
- structured-data parsers / `builtin.jpk` parser work
- ESM/NIF/TES-oriented binary format packages
- VFS/BSA/BA2/openmw-config-related package work where applicable
- compression codec experiments
- Magick/image/tooling workloads
- `st4sh` tooling
- r3versal/reverse-engineering workloads
- Doom/game-simulation package work
- any additional extant JPKs present by the time this handoff is executed

Do not trust this list to be complete.

**Inventory the actual tree first.**

For each package identify:

```text
package
benchmark/workload
hot Luau functions
native-block %
VM exits
allocation behavior
buffer traffic
string traffic
hash/table traffic
branch-heavy work
numeric/vector work
cross-boundary calls
candidate shared operation
```

Produce one master table.

---

# First-priority primitive family: packed typed buffer operations

This is probably the largest common opportunity.

A remarkable number of the current packages reduce to:

> bytes exist in a buffer; Luau needs to interpret, transform, compare, copy, scan, or emit them efficiently.

Applicable consumers include:

- NIF decoding
- ESM decoding
- archive formats
- JSON/YAML/TOML
- compression codecs
- HTTP parsing
- networking serialization
- Doom/WAD parsing
- Recast mesh data
- scene packed storage
- reverse-engineering tools

Investigate whether L3i needs stronger operations around contiguous typed buffer access.

Candidates include concepts equivalent to:

```text
read_u16_le
read_u32_le
read_u64_le

read_i16_le
read_i32_le
read_i64_le

read_f32_le
read_f64_le
```

but do **not** stop at scalar reads if scalar calls remain the problem.

Profile compound reads such as:

```text
read_f32x2
read_f32x3
read_f32x4

read_mat3_f32
read_affine3x4_f32
read_mat4_f32
```

or compiler lowering that recognizes consecutive buffer loads and fuses them.

The NIF work in particular should stress matrix/vector decoding hard enough to establish whether this matters.

The design objective is not “add NIF matrix support.”

It is:

> Make repeated structured numeric reads from packed byte storage cheap enough that binary formats naturally stay in Luau.

Benchmark both call overhead and resultant object/allocation behavior.

---

# Second-priority family: bulk packed numeric transforms

`dream.scene`, physics, navigation and rendering-adjacent presentation code all repeatedly perform operations over large packed numeric populations.

The scene profiler currently identifies these possible candidates:

1. affine parent × local 3×4 transform composition;
2. transforming a local AABB through an affine matrix;
3. reducing N child AABBs into one parent AABB;
4. batched frustum/AABB tests;
5. packed masked traversal / result emission.

Do not implement these merely because they appear on this list.

Cross-check them against:

- Recast/nav geometry
- physics broadphase/narrowphase preparation
- NIF transform processing
- renderer-facing presentation structures
- any spatial index packages

Look specifically for operations where Luau is spending large amounts of time doing repeated scalar loads/stores around a tiny fixed mathematical kernel.

### Candidate affine composition primitive

Something semantically equivalent to:

```text
affine_mul(dstBuffer, dstOffset,
           parentBuffer, parentOffset,
           localBuffer, localOffset)
```

or preferably a compiler-lowered equivalent.

Stress:

- one operation
- batches of 64
- batches of 1k
- batches of 100k
- aliasing
- contiguous source/destination arrays
- interleaved struct layouts
- structure-of-arrays layouts

A bulk form may outperform a per-item native call sufficiently to justify a different API:

```text
affine_mul_batch(...)
```

This is exactly the kind of question profiling must settle.

---

# Third-priority family: AABB / bounds kernels

Bounds processing has now appeared in scene graphs, physics and navigation.

Potential reusable operations:

```text
aabb_union
aabb_union_many
aabb_transform_affine
aabb_intersects
aabb_contains
aabb_distance2
frustum_intersects_aabb
```

However, tiny scalar helpers may already inline well enough that native calls lose.

The most promising candidates are therefore probably **bulk/reduction forms** rather than one-box operations.

Especially investigate:

```text
reduce packed child bounds → parent bound

test packed bounds array against query box

test packed bounds array against frustum planes
```

We want to discover whether there is a generally useful “operate over packed fixed-stride records” capability hiding underneath these domain-specific examples.

---

# Fourth-priority family: scanning/search primitives

The parser, HTTP, file-format, reverse-engineering and compression ecosystems all perform byte searching.

Audit how much time is spent doing things conceptually equivalent to:

```text
find next newline
find next quote
find next delimiter
find next byte satisfying class
find first non-whitespace
find one of N delimiters
find zero byte
compare fixed prefix
```

Potential primitive family:

```text
buffer.find_byte(...)
buffer.find_any(...)
buffer.find_not(...)
buffer.count(...)
buffer.starts_with_at(...)
```

Potentially also string equivalents where appropriate.

The desirable implementation may exploit native word-at-a-time scanning/SIMD internally while exposing simple deterministic semantics to Luau.

Parser benchmarks should include:

- JSON
- TOML
- YAML
- INI if still available
- HTTP headers
- large ESM/NIF names/string tables
- WAD/directory-ish data if useful

The critical question is whether one generic scanning facility accelerates all of these enough to matter.

---

# Fifth-priority family: fast numeric text parsing/formatting

Our serde-removal/parser work makes numeric conversion important.

Measure Luau-side parsing of:

```text
signed decimal integers
unsigned decimal integers
hex integers
floating point
scientific notation
```

against native/Rust paths.

Candidate primitives might expose low-level parsing from a byte span:

```text
parse_i64(buffer, begin, end)
parse_u64(...)
parse_f64(...)
```

Returning both value and resulting offset may avoid substring allocation.

Likewise investigate formatting if serializers or HTTP/compression tooling spend meaningful time emitting numbers.

Again: no primitive without profile evidence.

---

# Sixth-priority family: intern/hash operations

ESM/NIF/config/parser workloads repeatedly encounter identifiers and names.

Scene/resource systems also increasingly use stable numeric identities.

We have already been interested in returning compact numeric tokens rather than allocating rich wrapper objects.

Profile:

- string hashing
- string-table lookup
- repeated identifier comparison
- case-normalized lookup
- object/record ID handling
- archive path lookup
- parser keys
- resource names

Investigate whether a generic high-performance hash/intern primitive would remove significant work from several packages.

Possibilities include:

```text
hash bytes/span without substring allocation
case-insensitive ASCII hash
intern immutable byte/string span
stable numeric symbol token
```

Be extremely careful about lifetime and global-state semantics.

We do **not** want an invisible global interner that becomes an immortal memory leak.

A scoped/package-owned arena or explicit interner object may be better if an interner proves worthwhile.

If hashing alone provides most of the speedup, expose hashing and leave policy in Luau.

---

# Seventh-priority family: bitstream and integer packing

Compression codecs, network protocols, archives, reverse-engineering tools and game formats all need bit-level IO.

Benchmark Luau implementations of:

```text
read N bits
write N bits
zigzag encode/decode
varint encode/decode
bitpack/unpack
leading/trailing zero operations
population count
byte swap
rotate
```

Some of these should ideally lower directly to machine instructions.

Compression benchmarking is especially important because it can expose whether the Rust binding wins because of the compression algorithm itself or simply because Luau is paying enormous overhead manipulating bits and bytes one operation at a time.

The target is ambitious:

> Determine whether Luau compression implementations can approach or beat the effective package-level throughput of Rust binding implementations once boundary conversion/call overhead is included.

Run both tiny and large payloads.

Bindings often lose badly on tiny inputs even when their core implementation is much faster.

That distinction matters.

---

# Eighth-priority family: bulk memory operations

Audit usage and performance of:

```text
copy
move
fill
zero
compare
xor
swap/copy endian
gather/scatter
```

over buffers.

Especially look for code manually looping merely to move or initialize bytes.

Potentially useful primitives:

```text
buffer.copy
buffer.move
buffer.fill
buffer.compare
buffer.xor
```

Some may already exist; if so, benchmark their lowering and call overhead instead of reimplementing them.

Look for opportunities where existing primitives need better compiler recognition rather than additional API.

---

# Ninth-priority family: packed traversal / iteration

The scene graph currently sees approximately:

- 100k collect-all: ~6.85 ms
- 100k whole-world AABB query: ~9.05 ms
- 100k view collection: ~8.18 ms
- 1m collect-all: ~147.8 ms

Tiny spatial queries are already good because hierarchical rejection prevents traversal.

Before inventing a scene traversal primitive, determine **where the remaining broad traversal cost actually lives**:

- hierarchy link loads?
- branch prediction?
- generation-safe handle encoding?
- Lua table result growth?
- stack management?
- mask comparisons?
- function dispatch?
- result allocation?

This could reveal a much more generally useful primitive.

For example, if emitting 100k numeric results into a Lua table dominates, the solution may be a bulk numeric result buffer—not native scene traversal.

Compare traversal workloads in:

- scene hierarchy
- BVH/grid/navmesh
- ECS-like packed populations
- parser token streams
- archive directory walks

Search for the common denominator.

---

# Tenth-priority family: allocation-free temporary storage

Several systems need short-lived work queues/stacks/result vectors.

Profile temporary:

- arrays
- traversal stacks
- dirty lists
- query result sets
- parser token arrays
- geometry scratch
- network serialization buffers

Look at GC/allocation pressure.

Potential generic solutions include:

- reusable typed scratch buffers;
- growable numeric buffers;
- arenas/resettable storage;
- cheap result slices/views;
- stack/vector structures optimized for numeric values.

Do not introduce opaque native collections unless they beat straightforward Luau tables/buffers in meaningful complete workloads.

---

# Integer semantics

Explicitly investigate where exact integer behavior is important.

Current/potential users include:

- binary formats
- handles
- file offsets
- hashes
- bitstream codecs
- protocol fields
- Doom-era fixed/integer simulation
- archive directory metadata
- reverse-engineering workloads

We have already found numeric-token approaches attractive because they can avoid object allocation.

Determine whether current L3i integer support/lowering is sufficient for:

```text
u32/i32
u64/i64
bitwise operations
exact shifts
overflow-defined arithmetic where required
packing/unpacking
numeric handles
```

Do not add integer object wrappers.

The entire point is to keep these values cheap.

---

# Compiler lowering vs explicit API

Every candidate must be evaluated in two forms where sensible:

### Explicit primitive

```lua
local c = l3i.affineMul(a, b)
```

### Recognized/lowered idiom

```lua
-- ordinary-looking Luau that compiler recognizes
```

The second is often preferable because packages remain portable and readable.

However, do not force compiler magic where explicit bulk operations communicate intent better.

Produce a recommendation for each candidate:

```text
ordinary Luau
compiler intrinsic/lowering
builtin function
buffer method
JPK library implementation
reject entirely
```

---

# Boundary-crossing discipline

Measure the cost of entering Rust/native code.

This is critical.

A primitive that executes 8 arithmetic instructions but requires an expensive boundary transition may be slower than optimized Luau.

Prefer:

```text
one bulk operation over 10,000 elements
```

to:

```text
10,000 tiny native calls
```

unless lowering removes the boundary entirely.

Every benchmark should therefore distinguish:

```text
native kernel throughput
effective Luau caller throughput
total workload throughput
```

We care about the third number.

---

# Mandatory scene workload

Use `dream.scene` as one concrete stress corpus.

Current packed memory cost:

```text
200 bytes/node
```

Approximately:

```text
1k       0.191 MiB
10k      1.908 MiB
100k    19.074 MiB
250k    47.684 MiB
1m     190.735 MiB
```

Current final performance:

| Nodes | Build + realize | Idle | Dirty leaf | Dirty ~64 subtree | Dirty 1% | Collect all | Tiny query | Whole query | View collect |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1k | 0.786 ms | 0.00016 ms | 0.00226 ms | 0.0104 ms | 0.0148 ms | 0.0416 ms | 0.00060 ms | 0.0550 ms | 0.0634 ms |
| 10k | 8.44 ms | 0.00020 ms | 0.00678 ms | 0.0148 ms | 0.143 ms | 0.428 ms | 0.00874 ms | 0.592 ms | 0.567 ms |
| 100k | 100.85 ms | 0.00041 ms | 0.126 ms | 0.0844 ms | 4.10 ms | 6.85 ms | 0.0910 ms | 9.05 ms | 8.18 ms |
| 250k | 281.30 ms | 0.00050 ms | 0.194 ms | 0.189 ms | 11.97 ms | 17.27 ms | 0.416 ms | 27.39 ms | 25.14 ms |

Million-node sanity result:

```text
batch build + realization   ~1.407 s
tiny AABB query             ~0.699 ms
collect all handles         ~147.77 ms
```

Known ugly workload:

```text
create+destroy 1,000 leaves across many parents
repair affected bounds
100k-node existing scene
≈74.8 ms
```

Do not necessarily optimize that workload inside the persistent graph; ephemeral populations may belong in an instance/particle structure.

Use the profiler to distinguish architectural misuse from primitive weakness.

---

# Mandatory NIF/ESM workload

Stress binary parsing hard.

Specifically measure:

- scalar buffer reads
- vec2/vec3/vec4 reads
- matrix reads
- local→world transform processing
- strings/names
- record headers
- repeated identifier lookups
- lazy field decoding
- large-file traversal
- object construction/allocation

Compare:

```text
existing Rust path if available
native binding called from Luau if available
pure/current Luau implementation
Luau + candidate primitive
```

This workload should tell us whether compound packed reads and interning/hash primitives are worthwhile.

---

# Mandatory parser workload

Use real substantial inputs for:

- JSON
- TOML
- YAML
- INI where useful
- config-style files
- HTTP header parsing

Measure:

- delimiter scanning
- whitespace scanning
- numeric parsing
- escape handling
- key hashing
- substring creation
- output-table construction

The serializer/parser ecosystem is one of our best ways to identify generic byte-scanning weaknesses.

---

# Mandatory compression workload

Implement or use at least several codecs in Luau and compare against their Rust-bound equivalents.

Measure across input sizes:

```text
32 B
128 B
1 KiB
16 KiB
256 KiB
1 MiB+
```

Measure:

```text
encode
decode
ratio
effective throughput
allocations
binding conversion cost
```

Determine whether common bitstream/buffer primitives could allow Luau to compete much more aggressively.

Do not optimize merely for a single codec.

---

# Mandatory physics/navigation workload

Profile both the 2D physics and Recast/navigation packages.

Look for overlap around:

- vector operations
- AABBs
- min/max reductions
- geometry predicates
- packed iteration
- cell/grid processing
- triangle operations
- numeric scratch arrays

A geometry primitive is interesting only if it crosses package boundaries or represents an obvious machine-level operation that Luau systematically cannot express efficiently.

Avoid turning L3i into `libgeometry.so`.

---

# Mandatory game workload

Use Doom as a complete-system reality check.

Microbenchmarks lie.

Run an actual substantial simulation workload and determine whether proposed primitives:

- improve frame/simulation throughput;
- reduce VM/native transitions;
- reduce allocation;
- improve networking/state serialization;
- improve WAD/resource parsing;
- improve fixed/integer-heavy logic where applicable.

A primitive that looks wonderful in isolation and produces zero measurable Doom/game-level benefit should receive a much lower priority.

---

# Candidate primitive scoreboard

For every proposal produce something like:

| Primitive | Scene | NIF/ESM | Parser | Compression | Physics | Nav | HTTP | Doom | Other | Complexity |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| packed compound reads |  | ✓ | ✓ | ✓ |  | ✓ | ✓ | ✓ | ... | low |
| byte-span scan |  | ✓ | ✓ | ✓ |  |  | ✓ | ✓ | ... | low |
| affine batch compose | ✓ | ✓ |  |  | maybe | maybe |  |  | ... | medium |
| AABB reduction | ✓ | maybe |  |  | ✓ | ✓ |  |  | ... | low |
| bitstream ops |  | maybe |  | ✓ |  |  | ✓ | ✓ | ... | medium |
| span hash | maybe | ✓ | ✓ | maybe |  |  | ✓ | ✓ | ... | low |

Fill this with measured data.

Do not use checkmarks based merely on theoretical applicability.

---

# Acceptance threshold

A primitive should normally satisfy at least one of these:

### Cross-ecosystem primitive

Meaningfully improves **two or more unrelated JPKs**.

### Transformative primitive

Produces a very large improvement in one critical workload while being obviously low-level/general-purpose.

### Compiler-enabling primitive

Unlocks a pattern that allows many Luau implementations to remain in Luau instead of needing native rewrites.

As a starting heuristic, be skeptical of additions producing only ~5–10% isolated microbenchmark gains unless they are essentially free to maintain.

Prefer things producing:

- substantial complete-workload speedups;
- major allocation reductions;
- elimination of repeated VM/native crossings;
- radically faster packed-data processing;
- strong wins in multiple packages.

---

# Things we explicitly do NOT want

Do not solve this by adding:

```text
SceneNode
NavMesh
ESMReader
NIFObject
PhysicsBody
DoomThing
HTTPMessage
JSONDocument
```

to L3i.

Do not privilege current JPKs in the runtime.

Do not move whole JPK implementations into Rust because Rust wins a benchmark.

Do not expose unsafe native pointers merely for speed.

Do not produce APIs whose semantics depend on arbitrary C++/Rust layouts.

Do not use hidden permanent allocations to make benchmarks look good.

Do not sacrifice deterministic/sandboxable behavior without an extremely strong reason.

Do not benchmark only toy inputs.

Do not report percentages without raw timings.

Do not silently discard candidate primitives that lose—record the failures too.

Negative profiling data is useful.

---

# Implementation strategy

Work in rounds.

## Round 1 — ecosystem inventory

Inventory every JPK and every existing benchmark.

Add missing repeatable benchmarks.

Capture baseline profiles.

Do not modify L3i yet.

Deliver:

```text
baseline/
    package matrix
    benchmark commands
    raw timings
    profiler captures
    suspected common patterns
```

## Round 2 — candidate clustering

Cluster hotspots by underlying operation.

Example:

```text
NIF matrix reads
ESM numeric field reads
Recast vertex loads
compression word loads
HTTP integer parsing
```

may reveal:

```text
packed structured buffer reads
```

Likewise:

```text
scene subtree bounds
physics broadphase bounds
nav region bounds
```

may reveal:

```text
packed min/max reductions
```

Rank candidates by expected cross-JPK value.

## Round 3 — prototype primitives

Implement the smallest plausible primitive set.

Do not immediately polish API design.

Benchmark prototypes first.

## Round 4 — consumer integration

Modify representative JPKs to use candidate primitives.

Where possible, test both:

```text
explicit primitive usage
compiler-lowered idiomatic usage
```

## Round 5 — whole-ecosystem regression

Run every benchmark again.

For each primitive report:

```text
packages improved
packages unchanged
packages regressed
code-size impact
compile-time impact
runtime complexity
maintenance cost
```

## Round 6 — murder the weak

Delete primitives that are:

- too specific;
- slower than Luau;
- redundant;
- impossible to reason about safely;
- only useful in synthetic benchmarks;
- maintenance-heavy for tiny gains.

We want the smallest winning set.

---

# Profiling requirements

Capture more than elapsed wall time.

Where available report:

- median
- p95/p99 if meaningful
- CPU time
- allocation count/bytes
- GC activity
- native-block percentage
- VM exits
- calls across Luau/native boundary
- bytes read/written
- elements processed
- throughput
- memory footprint

Use warmup.

Use release builds.

Use pinned/repeatable workloads where possible.

Retain raw data.

Every claim in the final report should be reproducible.

---

# Important analytical question

For every hotspot ask whether the real limitation is:

```text
algorithm
representation
compiler lowering
missing machine operation
allocation
native call overhead
memory bandwidth
cache layout
branch behavior
hash/table behavior
string handling
buffer API
GC
```

A primitive is only the answer to some of these.

The scene graph already demonstrated how catastrophically misleading it would have been to treat an algorithmic problem as a native-code problem.

---

# Desired final output

Produce a large engineering report containing:

## 1. Ecosystem performance map

All JPKs, their workloads, hot paths and bottleneck classes.

## 2. Shared primitive opportunities

Ranked by demonstrated cross-package impact.

Do **not** rank political candidates. You may rank these computer primitives mercilessly.

## 3. Implemented prototypes

Exact semantics and code locations.

## 4. Before/after package results

Raw timings and relative changes.

## 5. Rejected candidates

What we tried and why it lost.

## 6. Compiler recommendations

Cases where new syntax/API is unnecessary because L3i should recognize/lower existing Luau.

## 7. Remaining JPK-local problems

Hotspots that should stay package-specific.

## 8. Proposed L3i patch set

Ideally organized as independent commits by primitive family.

## 9. Benchmark suite

Everything necessary to re-run the experiment later as JPKs evolve.

---

# Working hypothesis

The wager behind this exercise is:

> We do not need a giant native game engine underneath Luau.

We may instead need a small collection of extremely good operations for:

```text
packed bytes
packed numbers
integer/bit manipulation
bulk math
scanning
hashing
reductions
memory movement
allocation-free scratch/results
```

If that hypothesis is correct, improvements motivated by one JPK should repeatedly make apparently unrelated JPKs faster.

That is what we are trying to prove or disprove.

The success criterion is not:

> “scene.jpk got faster.”

It is:

> “we found five tiny L3i improvements and suddenly scene, NIF, ESM, parsers, compression, navigation, physics, HTTP, reverse-engineering tools and game runtimes all got varying degrees of faster without moving their architecture out of Luau.”

If we can make that happen, **keep turning the fucking crank.**
