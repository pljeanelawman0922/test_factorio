# Belt Balancer Planner (Factorio 2.1)

Drag over the gap between where your input belts end and your output belts
begin. The mod finds a balancer that fits in the selection, routes the belts
to it, and places ghosts for your robots (or you) to build.

## Using it

| Action | How |
|---|---|
| Get the tool | Shortcut bar button, or **Alt + B** |
| Plan a balancer | Drag over the gap |
| Remove planned ghosts in an area | **Shift + drag** with the tool |
| Remove the last planned balancer | **Shift + Alt + B** |

Set up the belts first:

1. Lay the **input belts** so they end (point into empty ground) inside the
   area you will select.
2. Lay the **output belts** so they start inside the area and leave it.
3. Drag over the gap so the selection border crosses every input and output
   belt.

Belt tier: the new belts, splitters and undergrounds match the fastest (or,
per player setting, the slowest) of the selected belts. Modded tiers are found
by belt speed.

## What it can build

| Inputs → outputs | Design used |
|---|---|
| 1 → 1 | lane balancer (also evens out the two lanes) |
| 2 → 1, 3 → 1, 4 → 1 | merger |
| 1 → 2, 2 → 2 | 2 → 2 |
| 3 → 2, 4 → 2 | 4 → 2 |
| 1 → 3, 2 → 3, 3 → 3 | 3 → 3 (4 → 4 with a loop-back) |
| 1 → 4, 2 → 4 | 2 → 4 |
| 3 → 4, 4 → 4 | 4 → 4 |

Not supported yet: 4 → 3 and anything above 4 belts. Belt balancers keep
lanes separate (left lanes are balanced among themselves, right lanes among
themselves), as splitters do in the game. The 4 → 2, 4 → 4 and 3 → 3 designs
are throughput limited: they balance exactly, but under some uneven loads
they move less than the full input.

## How it works

```
selection ─▶ detect ends ─▶ pick designs ─▶ try placements ─▶ route belts ─▶ ghosts
```

1. **Detect.** Every belt or underground exit in the selection that points
   into empty ground is an input end; every belt or underground entrance with
   nothing feeding it is an output start. The belt chain is traced to check
   that inputs come from outside the selection and outputs leave it, so stray
   belt pieces inside the gap are ignored.
2. **Pick designs.** Designs are ASCII templates (`scripts/templates.lua`)
   with an exact output count and a maximum input count. A true balancer
   stays balanced when some inputs are empty, so a 4 → 4 also serves 3 → 4.
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
5. **Build.** The cheapest successful layout is placed as ghosts. If any
   ghost fails to place, the whole layout is rolled back.

The planner (`scripts/planner.lua`) is pure Lua with no game API calls, so it
is tested outside the game. Planning is deterministic (safe in multiplayer)
and capped by a work budget so a hopeless selection gives up quickly.

## Files

```
info.json, data.lua, settings.lua   prototypes: tool, shortcut, hotkeys, settings
control.lua                         events, world scan, tier choice, ghost placement
scripts/planner.lua                 detection, placement search, routing
scripts/templates.lua               balancer designs
locale/en, locale/ru                English and Russian text
tools/sim.py                        lane-level belt flow simulator, verifies templates
tools/test_planner.py               planner tests + random fuzzing, verified by the simulator
tools/test_control.py               control.lua against a mock of the game API
```

## Adding a design

Draw it in `scripts/templates.lua`, flowing north, inputs on the last row and
outputs on the first:

```
^ > v <   belts        S s   splitter (left, right half)
D / U     underground entrance / exit facing north
e / E     underground entrance / exit facing east (w / W: west)
.         empty
```

Then run the checks (needs Python 3 and `pip install lupa`):

```
python3 tools/sim.py            # proves every design balances, also with inputs left empty
python3 tools/test_planner.py   # placement + routing, every planned layout re-verified
python3 tools/test_control.py   # control.lua against a mock game API
```

The simulator models straight belts, curves, side-loading, splitters
(including blocked outputs) and undergrounds lane by lane, and fails a design
if any input lane does not reach every output equally.

## Known limitations

* Routes are plain belts; they don't use undergrounds to cross other belts.
  If belts must cross to reach the balancer, give the selection more room or
  move the belt ends.
* Trees and rocks in the way are not marked for deconstruction; clear them
  first.
* Undo (Ctrl + Z) doesn't cover the placed ghosts; use Shift + drag or
  Shift + Alt + B.
* Selections are limited to 64 × 64 tiles.
