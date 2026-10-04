# Belt Balancer Planner (Factorio 2.1)

Drag a rectangle over where your input belts end and your output belts
begin. The mod finds a balancer that fits in the selection, routes the belts
to it (going underground where it has to), marks trees, rocks and cliffs in
the way for removal, and places ghosts for your robots (or you) to build.

## Using it

| Action | How |
|---|---|
| Get the tool | Shortcut bar button, or **Alt + B** |
| Plan a balancer | Drag over the belt ends (or the gap between them) |
| Remove planned ghosts in an area | **Shift + drag** with the tool |
| Remove the last planned balancer | **Shift + Alt + B** |

Set up the belts first:

1. Lay the **input belts** so they end (point into empty ground) inside the
   area you will select.
2. Lay the **output belts** so they start inside the area (nothing feeding
   them).
3. Drag a rectangle over the belt ends with free ground for the balancer in
   between.

Belts may cross the selection border or lie completely inside it; even a
single belt piece counts. A belt coming in from outside is an input, one
leaving the selection is an output. For a piece lying completely inside, the
mod looks at the other selected belts: if more of them are ahead of the
piece (in its direction) than behind it, it is an input, otherwise an
output. Example: one belt on the left and three on the right, all facing
east, is 1 input → 3 outputs.

A design's input or output belt may be your own belt end when it already
sits in the right place and faces the right way; then nothing is built
there. Example: one belt, then 4 free tiles, then three belts stacked
beside each other, all facing the same way, takes exactly the 1 → 3 design.

If the design doesn't fit, the message gives the size of the design itself
and, when one works, a selection size for the same belts (the planner tries
1 to 3 more tiles on each side).

Belt tier: the new belts, splitters and undergrounds match the fastest (or,
per player setting, the slowest) of the selected belts. Modded tiers are found
by belt speed.

## What it can build

Any count from 1 to 16 inputs and 1 to 16 outputs, as long as the design fits
in the selection.

| Inputs → outputs | Design used |
|---|---|
| 1 → 1 | lane balancer (also evens out the two lanes) |
| 2 → 1, 3 → 1, 4 → 1 | merger |
| 1 → 2, 2 → 2 | 2 → 2 |
| 3 → 2, 4 → 2 | 4 → 2 |
| 1 → 3 | 1 → 3 splitter with a loop-back (4 × 6) |
| 1 → 3, 2 → 3, 3 → 3 | 3 → 3 (4 → 4 with a loop-back) |
| 1 → 4, 2 → 4 | 2 → 4 |
| 3 → 4, 4 → 4 | 4 → 4 |
| anything else up to 16 → 16 | generated (see below) |

Generated designs (`scripts/generator.lua`):

* **Core:** a P × P butterfly balancer, P = 2, 4, 8 or 16 (the smallest that
  has at least as many outputs as needed): log2(P) splitter layers; between
  layers the belts are re-arranged with undergrounds so every splitter gets
  one belt from each half.
* **Fewer outputs than P** (3, 5, 6, 7, 9 to 15): the spare outputs loop back
  around the sides into spare inputs. Items that go round a loop are spread
  again, so they end up evenly on the real outputs.
* **More inputs than outputs:** inputs are first merged in groups (sizes
  differ by at most one) down to the output count.

Rough sizes (width × length, yellow undergrounds): 4 → 3: 7 × 11,
6 → 6: 11 × 20, 8 → 8: 9 × 18, 16 → 16: 24 × 38. The selection needs a few
more tiles than that for the belts to reach the balancer.

Belt balancers keep lanes separate (left lanes are balanced among
themselves, right lanes among themselves), as splitters do in the game. The 4 → 2, 4 → 4, 3 → 3 and
generated designs are throughput limited: they balance exactly, but under
some uneven loads they move less than the full input. Merged inputs are not
drawn evenly when the outputs back up.

Balanced means equal *amounts* per output, not mixed *items*. When both
inputs of a splitter are full, the game passes them almost straight
through, so with different items on the input belts the outputs can carry
different items even though each carries the same number. Designs with
spare inputs are only used when one without spare inputs doesn't fit
(e.g. 2 → 4 instead of 4 → 4 for two belts).

## How it works

```
selection ─▶ detect ends ─▶ pick / generate design ─▶ try placements ─▶ route belts ─▶ clear + ghosts
```

1. **Detect.** Every belt or underground exit in the selection that points
   into empty ground is an input end; every belt or underground entrance with
   nothing feeding it is an output start. The belt chain is traced: an end
   fed from outside the selection is an input, a start leading out of it is
   an output. Pieces lying completely inside are paired up (start → end) and
   classified by how many of the other belts lie ahead of / behind them.
2. **Pick designs.** Designs are ASCII templates (`scripts/templates.lua`)
   with an exact output count and a maximum input count. A true balancer
   stays balanced when some inputs are empty, so a 4 → 4 also serves 3 → 4.
   Counts without a hand-drawn template get a generated one.
3. **Try placements.** Each design is tried in all 4 rotations and both
   mirror images at every offset inside the selection. A placement is kept if
   every tile is buildable (the game's own ghost placement check), nothing
   already on the ground pushes items into it, its undergrounds don't cut
   through existing underground pairs, and its outputs have somewhere to go.
   Placements are ranked by estimated belt length.
4. **Route.** Inputs and outputs are paired in sweep order around the ports
   (this gives nested, non-crossing routes, also around corners). Belts are
   routed with A* on the tile grid with a turn penalty, using negotiated
   congestion: routes may share tiles at a price that rises every round, and
   are ripped up and re-routed until no tile is shared. Routes never use a
   tile that some other belt pushes into, so nothing side-loads by accident.
   Plain belts are tried first; if that fails, routes may also use
   underground belts to pass under other belts, splitters, rocks or water.
   An underground pair claims its whole line, so it never pairs with another
   underground (existing, the balancer's own, or another route's). To get
   out or in, a route may turn an input end, an output start or a balancer
   port into an underground of the same direction (the input belt must be
   fed straight from behind).
5. **Clear.** Tiles with trees, rocks or cliffs count as buildable at an
   extra cost (cliffs only with cliff explosives researched). Whatever the
   chosen layout covers is marked for deconstruction; nothing of yours is
   ever marked, except input/output belts replaced by undergrounds.
6. **Build.** The cheapest successful layout is placed as ghosts. If any
   ghost fails to place, the whole layout is rolled back, including the
   deconstruction marks. Shift + Alt + B (and Shift + drag over the whole
   build) also cancel the marks.

The planner (`scripts/planner.lua`) is pure Lua with no game API calls, so it
is tested outside the game. Planning is deterministic (safe in multiplayer)
and capped by a work budget so a hopeless selection gives up quickly.

## Files

```
info.json, data.lua, settings.lua   prototypes: tool, shortcut, hotkeys, settings
control.lua                         events, world scan, tier choice, clearing, ghost placement
scripts/planner.lua                 detection, placement search, routing
scripts/templates.lua               hand-drawn balancer designs
scripts/generator.lua               balancer designs for any count up to 16 → 16
locale/en, locale/ru                English and Russian text
tools/sim.py                        lane-level belt flow simulator, verifies templates
tools/test_generator.py             every generated design, verified by the simulator
tools/test_planner.py               planner tests + random fuzzing, verified by the simulator
tools/test_control.py               control.lua against a mock of the game API
```

## Adding a design

Draw it in `scripts/templates.lua`, flowing north, inputs on the last row and
outputs on the first:

```
^ > v <   belts        S s   splitter (left, right half)
                       K/k   splitter facing east (K on top)  J/j   facing west (J below)
D / U     underground entrance / exit facing north
e / E     underground entrance / exit facing east (w / W: west)
.         empty
```

Then run the checks (needs Python 3 and `pip install lupa`):

```
python3 tools/sim.py              # proves every design balances, also with inputs left empty
python3 tools/test_generator.py   # every generated design 1..8 → 1..8 (--all: up to 16)
python3 tools/test_planner.py     # placement + routing, every planned layout re-verified
python3 tools/test_control.py     # control.lua against a mock game API
```

The simulator models straight belts, curves, side-loading, splitters
(including blocked outputs) and undergrounds lane by lane, and fails a design
if any input lane does not reach every output equally.

## Known limitations

* The balancer itself can't straddle an existing belt; routes can go under
  belts, the balancer can't. Leave a clear stretch at least as long as the
  design.
* 3, 5, 6, 7 and 9 to 15 outputs need loop-backs, which make those designs
  longer and wider than the belt bundle. 3 → 3 needs a gap of about 12 tiles,
  6 → 6 about 12 × 22.
* Undo (Ctrl + Z) doesn't cover the placed ghosts; use Shift + drag or
  Shift + Alt + B.
* Selections are limited to 64 × 64 tiles.
