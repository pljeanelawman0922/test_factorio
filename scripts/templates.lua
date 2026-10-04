-- Balancer template library.
--
-- Every template is drawn in a local frame where items flow NORTH (towards
-- row 1). Row 1 is the output side, the last row is the input side.
--
-- Cells are separated by whitespace. Symbols:
--   ^ > v <   transport belt facing that way
--   S s       splitter facing north: S = left (west) half, s = right half
--   K / k     splitter facing east: K = left (north) half, k = the tile below
--   J / j     splitter facing west: J = left (south) half, j = the tile above
--   D         underground belt entrance ("input")  facing north
--   U         underground belt exit     ("output") facing north
--   e / E     underground entrance / exit facing east
--   w / W     underground entrance / exit facing west
--   .         empty (must stay free of belts; may be under an underground)
--
-- Ports:
--   Every non-empty cell of the LAST row is an input port, every non-empty
--   cell of the FIRST row is an output port. Ports must be plain belts facing
--   north. Unused input ports are simply not built.
--
-- Fields:
--   inputs   maximum number of input belts (fewer is fine: a true balancer
--            stays balanced when some inputs are empty)
--   outputs  exact number of output belts
--   lane     true if the template also balances the two lanes of a belt
--   note     shown to the player
--
-- Every template here is checked by tools/sim.py: a lane-level flow model of
-- belts, curves, side-loading, splitters and undergrounds. Run
--   python3 tools/sim.py
-- after editing.

return {
  {
    name = "lane-1x1",
    inputs = 1, outputs = 1, lane = true,
    note = "1 → 1 lane balancer",
    grid = {
      ". ^ .",
      "> ^ <",
      "^ > ^",
      "S s .",
      ". ^ .",
    },
  },
  {
    name = "2x1",
    inputs = 2, outputs = 1,
    note = "2 → 1 merger",
    grid = {
      "^ .",
      "S s",
      "^ ^",
    },
  },
  {
    -- A (bottom) takes the input and a loop; its left output goes to the
    -- sideways splitter H, which feeds output 1 and loops back into A; its
    -- right output goes to B, which feeds outputs 2 and 3. Each output gets
    -- exactly a third.
    name = "1x3",
    inputs = 1, outputs = 3,
    note = "1 → 3 splitter (loop-back)",
    grid = {
      ". ^ ^ ^",
      "> ^ S s",
      "^ j < ^",
      "v J S s",
      "> > ^ ^",
      ". . . ^",
    },
  },
  {
    name = "2x2",
    inputs = 2, outputs = 2,
    note = "2 → 2 balancer",
    grid = {
      "^ ^",
      "S s",
      "^ ^",
    },
  },
  {
    name = "4x1",
    inputs = 4, outputs = 1,
    note = "4 → 1 merger",
    grid = {
      ". ^ . .",
      ". S s .",
      "S s S s",
      "^ ^ ^ ^",
    },
  },
  {
    name = "4x2",
    inputs = 4, outputs = 2,
    note = "4 → 2 balancer (throughput limited)",
    grid = {
      ". ^ ^ .",
      ". S s .",
      "S s S s",
      "^ ^ ^ ^",
    },
  },
  {
    name = "2x4",
    inputs = 2, outputs = 4,
    note = "2 → 4 balancer",
    grid = {
      "^ ^ ^ ^",
      "S s S s",
      ". S s .",
      ". ^ ^ .",
    },
  },
  {
    -- Two splitter layers; the left stream of layer 1 is carried under the
    -- other three lanes to the far right so every layer-2 splitter sees one
    -- half from each layer-1 splitter.
    name = "4x4",
    inputs = 4, outputs = 4,
    note = "4 → 4 balancer (throughput limited)",
    grid = {
      ". ^ ^ ^ ^",
      ". S s S s",
      ". U U U ^",
      "> e . E ^",
      "^ D D D .",
      "S s S s .",
      "^ ^ ^ ^ .",
    },
  },
  {
    -- The 4x4 with its rightmost output looped back into its 4th input.
    name = "3x3",
    inputs = 3, outputs = 3,
    note = "3 → 3 balancer (4 → 4 with loop-back, throughput limited)",
    grid = {
      ". ^ ^ ^ . .",
      ". ^ ^ ^ > v",
      ". S s S s v",
      ". U U U ^ v",
      "> e . E ^ v",
      "^ D D D . v",
      "S s S s . v",
      "^ ^ ^ ^ < <",
      "^ ^ ^ . . .",
    },
  },
}
