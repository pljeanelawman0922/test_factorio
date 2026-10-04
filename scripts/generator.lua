-- Builds balancer templates for any number of inputs and outputs.
--
-- The result is an ordinary template (see templates.lua): an ASCII grid in a
-- north-flowing frame, so the planner places and routes it like a hand-drawn
-- one. Everything is built bottom-up from "streams" (belts flowing north)
-- with four operations:
--
--   straight    every stream moves one tile north
--   splitters   adjacent streams share a splitter
--   merges      a splitter with one output left empty (2 belts -> 1)
--   move        some streams shift sideways on the surface while every
--               stream they cross dives under them (one underground pair)
--
-- Design for n inputs -> m outputs:
--
--   * n > m: inputs are merged in groups into m belts first.
--   * the core is a P x P butterfly balancer, P = smallest power of 2 >= m:
--     log2(P) splitter layers; between layers each block of 2s belts is
--     re-arranged so that every splitter gets one belt from each half.
--   * the P - m spare core outputs loop back around the sides into spare
--     core inputs. A balancer spreads every input evenly over all outputs,
--     so items going round a loop come back and end up evenly spread over
--     the m real outputs.
--
-- Every generated size is checked by tools/test_generator.py with the lane
-- flow simulator.

local gen = {}

gen.MAX = 16

local function ck(c, l) return c .. "," .. l end

local function new_builder(ug_max)
  return {cells = {}, keep = {}, streams = {}, level = 0, ug_max = ug_max}
end

local function put(b, c, l, sym)
  local k = ck(c, l)
  if b.cells[k] then error("generator: cell taken " .. k) end
  if b.keep[k] then error("generator: cell must stay empty " .. k) end
  b.cells[k] = {c = c, l = l, sym = sym}
end

local function sort_streams(b)
  table.sort(b.streams, function(p, q) return p.col < q.col end)
end

local function spawn(b, col)
  local s = {col = col}
  b.streams[#b.streams + 1] = s
  sort_streams(b)
  return s
end

local function straight(b, n)
  for _ = 1, n do
    for _, s in ipairs(b.streams) do put(b, s.col, b.level, "^") end
    b.level = b.level + 1
  end
end

-- pairs: list of {left_stream, right_stream}; merge: which side survives
-- ("L" / "R") or nil for a plain splitter
local function splitter_layer(b, pairs, merge)
  local used = {}
  for _, p in ipairs(pairs) do
    local l, r = p[1], p[2]
    if r.col ~= l.col + 1 then error("generator: splitter inputs not adjacent") end
    put(b, l.col, b.level, "S")
    put(b, r.col, b.level, "s")
    used[l], used[r] = true, true
  end
  for _, s in ipairs(b.streams) do
    if not used[s] then put(b, s.col, b.level, "^") end
  end
  if merge then
    local drop = {}
    for _, p in ipairs(pairs) do
      local gone = (merge == "R") and p[1] or p[2]
      drop[gone] = true
      -- the blocked splitter output must stay empty
      b.keep[ck(gone.col, b.level + 1)] = true
    end
    local keep = {}
    for _, s in ipairs(b.streams) do if not drop[s] then keep[#keep + 1] = s end end
    b.streams = keep
  end
  b.level = b.level + 1
end

-- Pair consecutive streams (1,2), (3,4), ... of `list` (sorted by column).
local function pair_up(list)
  local pairs = {}
  for i = 1, #list - 1, 2 do pairs[#pairs + 1] = {list[i], list[i + 1]} end
  return pairs
end

------------------------------------------------------------------ moves

-- One block: movers {st=, s=, t=}. Movers travel on the surface, each on
-- its own row (rows may be shared when the spans don't touch); every other
-- stream inside a mover's span dives under all of them.
local function move_block(b, movers)
  local n = #movers
  -- lower[j] = movers that must turn on a lower row than j
  local lower = {}
  for j = 1, n do lower[j] = {} end
  for i = 1, n do
    for j = 1, n do
      if i ~= j then
        local mi, mj = movers[i], movers[j]
        local lo, hi = math.min(mj.s, mj.t), math.max(mj.s, mj.t)
        -- j's row crosses i's source column: i's belt there must end below
        if mi.s >= lo and mi.s <= hi then table.insert(lower[j], i) end
        -- j's row crosses i's target column: i's belt there starts above
        if mi.t >= lo and mi.t <= hi then table.insert(lower[i], j) end
      end
    end
  end
  local h, state = {}, {}
  local function depth(j)
    if state[j] == 2 then return h[j] end
    if state[j] == 1 then error("generator: moves cross each other") end
    state[j] = 1
    local d = 1
    for _, i in ipairs(lower[j]) do d = math.max(d, depth(i) + 1) end
    state[j], h[j] = 2, d
    return d
  end
  local H = 0
  for j = 1, n do H = math.max(H, depth(j)) end

  local moving = {}
  for _, m in ipairs(movers) do moving[m.st] = m end
  local divers, dive = {}, {}
  for _, st in ipairs(b.streams) do
    if not moving[st] then
      for _, m in ipairs(movers) do
        if st.col == m.t then error("generator: move onto a standing belt") end
        if st.col > math.min(m.s, m.t) and st.col < math.max(m.s, m.t) then
          dive[st] = true
        end
      end
      if dive[st] then divers[#divers + 1] = st end
    end
  end
  local off = (#divers > 0) and 1 or 0
  if off == 1 and H + 1 > b.ug_max then error("generator: underground too long") end

  local base = b.level
  local function others(L, diver_sym)
    for _, st in ipairs(b.streams) do
      if not moving[st] then
        if dive[st] then
          if diver_sym then put(b, st.col, L, diver_sym) end
        else
          put(b, st.col, L, "^")
        end
      end
    end
  end
  if off == 1 then
    others(base, "D")
    for _, m in ipairs(movers) do put(b, m.s, base, "^") end
  end
  for row = 1, H do
    local L = base + off + row - 1
    others(L, nil)
    for j, m in ipairs(movers) do
      if row < h[j] then
        put(b, m.s, L, "^")
      elseif row == h[j] then
        local step = (m.t > m.s) and 1 or -1
        local arrow = (step == 1) and ">" or "<"
        for c = m.s, m.t - step, step do put(b, c, L, arrow) end
        put(b, m.t, L, "^")
      else
        put(b, m.t, L, "^")
      end
    end
  end
  if off == 1 then
    others(base + H + 1, "U")
    for _, m in ipairs(movers) do put(b, m.t, base + H + 1, "^") end
  end
  b.level = base + H + 2 * off
  for _, m in ipairs(movers) do m.st.col = m.t end
  sort_streams(b)
end

-- targets: stream -> new column. Splits into several blocks when the
-- divers' undergrounds would get too long.
local function move(b, targets)
  local movers = {}
  for _, st in ipairs(b.streams) do
    local t = targets[st]
    if t and t ~= st.col then movers[#movers + 1] = {st = st, s = st.col, t = t} end
  end
  if #movers == 0 then return end
  local batch = math.max(1, b.ug_max - 1)
  if #movers <= batch then return move_block(b, movers) end
  -- try in one block first (no divers -> no length limit)
  local snapshot_cells, snapshot_level = {}, b.level
  for k, v in pairs(b.cells) do snapshot_cells[k] = v end
  local ok = pcall(move_block, b, movers)
  if ok then return end
  b.cells, b.level = snapshot_cells, snapshot_level
  for _, m in ipairs(movers) do m.st.col = m.s end
  sort_streams(b)
  -- all movers must go the same way; move the far ones first
  local right = movers[1].t > movers[1].s
  for _, m in ipairs(movers) do
    if (m.t > m.s) ~= right then error("generator: mixed move needs batching") end
  end
  table.sort(movers, function(p, q)
    if right then return p.t > q.t end
    return p.t < q.t
  end)
  for i = 1, #movers, batch do
    local chunk = {}
    for k = i, math.min(#movers, i + batch - 1) do
      local m = movers[k]
      chunk[#chunk + 1] = {st = m.st, s = m.st.col, t = m.t}
    end
    move_block(b, chunk)
  end
end

------------------------------------------------------------------- core

-- Stage for stride s >= 4, any block layout: spread the Y half of every
-- block of 2s (one free column between Y belts, X(s-1) right next to Y0),
-- then X0..X(s-2) jump into the gaps. Wide (3s - 1 columns per block).
local function spread_and_jump(b, s)
  local order = b.streams
  local blocks = {}
  for i = 1, #order, 2 * s do
    local blk = {x = {}, y = {}}
    for k = 0, s - 1 do blk.x[k] = order[i + k]; blk.y[k] = order[i + s + k] end
    blocks[#blocks + 1] = blk
  end
  local T, prev = {}, nil
  for _, blk in ipairs(blocks) do
    for k = 0, s - 1 do
      local st = blk.x[k]
      T[st] = prev and math.max(st.col, prev + 1) or st.col
      prev = T[st]
    end
    for k = 0, s - 1 do
      local st = blk.y[k]
      T[st] = math.max(st.col, prev + ((k == 0) and 1 or 2))
      prev = T[st]
    end
    T[blk.x[s - 1]] = T[blk.y[0]] - 1
  end
  move(b, T)
  -- X(k) lands just left of Y(k+1)
  local targets = {}
  for _, blk in ipairs(blocks) do
    for k = 0, s - 2 do targets[blk.x[k]] = blk.y[k + 1].col - 1 end
  end
  move(b, targets)
end

-- Stride 4 in 9 columns: with a free column next to a block of 8
-- (X X X X Y Y Y Y), three single-belt moves give Y X X Y X Y . X Y.
-- Found by exhaustive search (rows = 9, the narrowest layout).
local NARROW4 = {{7, 0}, {3, 7}, {6, 3}}

local function narrow4(b)
  local order = b.streams
  local occ, wins = {}, {}
  for _, st in ipairs(order) do occ[st.col] = true end
  for i = 1, #order, 8 do
    local first, last = order[i].col, order[i + 7].col
    if last - first ~= 7 then return false end
    if not occ[first - 1] then
      occ[first - 1] = true
      wins[#wins + 1] = {o = first - 1, dir = 1}
    elseif not occ[last + 1] then
      occ[last + 1] = true
      wins[#wins + 1] = {o = last + 1, dir = -1}
    else
      return false
    end
  end
  for _, step in ipairs(NARROW4) do
    local at = {}
    for _, st in ipairs(b.streams) do at[st.col] = st end
    local targets = {}
    for _, w in ipairs(wins) do
      targets[at[w.o + w.dir * step[1]]] = w.o + w.dir * step[2]
    end
    move(b, targets)
  end
  return true
end

-- streams: the P core streams, sorted, contiguous columns.
local function core(b, P)
  splitter_layer(b, pair_up(b.streams))
  local s = 2
  while s < P do
    if s == 2 then
      -- [x0 x1 y0 y1] -> [x1 y0 y1 x0]: x0 jumps to the end of its block
      local order, targets = b.streams, {}
      for i = 1, #order, 4 do targets[order[i]] = order[i + 3].col + 1 end
      move(b, targets)
    elseif not (s == 4 and narrow4(b)) then
      spread_and_jump(b, s)
    end
    splitter_layer(b, pair_up(b.streams))
    s = s * 2
  end
end

------------------------------------------------------------------ build

local function draw_loops(b, lefts, rights, Lc, Ltop)
  local minc, maxc = math.huge, -math.huge
  for _, cell in pairs(b.cells) do
    minc = math.min(minc, cell.c)
    maxc = math.max(maxc, cell.c)
  end
  local function loop(o, inc, i, side)
    -- side = -1 (left) / 1 (right); i = 0 is the innermost loop
    local X = (side < 0) and (minc - 1 - i) or (maxc + 1 + i)
    local top, bot = Ltop + i, Lc - 1 - i
    for l = Ltop, top - 1 do put(b, o, l, "^") end
    local toward = (side < 0) and "<" or ">"
    for c = o, X - side, side do put(b, c, top, toward) end
    for l = top, bot + 1, -1 do put(b, X, l, "v") end
    local back = (side < 0) and ">" or "<"
    for c = X, inc + side, -side do put(b, c, bot, back) end
    for l = bot, Lc - 1 do put(b, inc, l, "^") end
  end
  for i, p in ipairs(lefts) do loop(p.out, p.inp, i - 1, -1) end
  for i, p in ipairs(rights) do loop(p.out, p.inp, i - 1, 1) end
end

local function to_grid(b)
  local minc, maxc, maxl = math.huge, -math.huge, 0
  for _, cell in pairs(b.cells) do
    minc = math.min(minc, cell.c)
    maxc = math.max(maxc, cell.c)
    maxl = math.max(maxl, cell.l)
  end
  local rows = {}
  for l = maxl, 0, -1 do
    local row = {}
    for c = minc, maxc do
      local cell = b.cells[ck(c, l)]
      row[#row + 1] = cell and cell.sym or "."
    end
    rows[#rows + 1] = table.concat(row, " ")
  end
  return rows
end

local function build_core(n, m, ug_max)
  local b = new_builder(ug_max)
  for i = 0, n - 1 do spawn(b, i) end
  straight(b, 1) -- input ports

  if n > m then
    -- merge into m groups (sizes differ by at most one), chained to the
    -- right inside each group
    local groups, i = {}, 1
    for g = 1, m do
      local size = math.floor(n / m) + ((g <= n % m) and 1 or 0)
      local grp = {}
      for k = i, i + size - 1 do grp[#grp + 1] = b.streams[k] end
      groups[g] = grp
      i = i + size
    end
    local round = 1
    while true do
      local pairs = {}
      for _, grp in ipairs(groups) do
        if grp[round + 1] then pairs[#pairs + 1] = {grp[round], grp[round + 1]} end
      end
      if #pairs == 0 then break end
      splitter_layer(b, pairs, "R")
      round = round + 1
    end
    straight(b, 1)
    if m > 1 then
      local targets, c0 = {}, b.streams[1].col
      for k, st in ipairs(b.streams) do targets[st] = c0 + k - 1 end
      move(b, targets)
    end
  end
  if m == 1 then
    straight(b, 1)
    return b
  end

  local P = 2
  while P < m do P = P * 2 end
  local loops = P - m
  local a = math.floor(loops / 2)
  local c = loops - a
  local K = #b.streams
  local first_real = a + math.floor((m - K) / 2)
  local O = b.streams[1].col - first_real
  local bottom = math.max(a, c)
  straight(b, bottom)
  local Lc = b.level

  local real = {}
  for k = 0, K - 1 do real[first_real + k] = true end
  local left_in, right_in = {}, {}
  for slot = 0, P - 1 do
    if not real[slot] then
      local st = spawn(b, O + slot)
      if slot < a then left_in[#left_in + 1] = st.col
      elseif slot >= P - c then right_in[#right_in + 1] = st.col end
    end
  end

  core(b, P)

  -- spare outputs loop back: the a leftmost to the left side, the c
  -- rightmost to the right side; the outermost output takes the outer loop
  local outs = b.streams
  local lefts, rights, keep = {}, {}, {}
  for k = 1, a do lefts[k] = {out = outs[k].col, inp = left_in[k]} end
  for k = 1, c do rights[k] = {out = outs[#outs - k + 1].col, inp = right_in[c - k + 1]} end
  for k = a + 1, #outs - c do keep[#keep + 1] = outs[k] end
  b.streams = keep
  local Ltop = b.level
  straight(b, bottom)
  straight(b, 1) -- output ports
  draw_loops(b, lefts, rights, Lc, Ltop)
  return b
end

-- Splits every stream into 2^k with splitter trees. Stream i owns columns
-- [base + (i-1) 2^k, base + i 2^k); at each level a stream sits just left of
-- the middle of its columns and a splitter halves them.
local function trees(b, k)
  local L = 2 ^ k
  local list = {}
  local base = b.streams[1].col
  for i, st in ipairs(b.streams) do list[i] = {st = st, a = base + (i - 1) * L, L = L} end
  for _ = 1, k do
    local targets = {}
    for _, v in ipairs(list) do targets[v.st] = v.a + v.L / 2 - 1 end
    move(b, targets)
    straight(b, 1)
    -- one splitter per stream; its right half has no input
    for _, v in ipairs(list) do
      put(b, v.st.col, b.level, "S")
      put(b, v.st.col + 1, b.level, "s")
    end
    b.level = b.level + 1
    local next_list = {}
    for _, v in ipairs(list) do
      local half = v.L / 2
      local right = spawn(b, v.st.col + 1)
      next_list[#next_list + 1] = {st = v.st, a = v.a, L = half}
      next_list[#next_list + 1] = {st = right, a = v.a + half, L = half}
    end
    list = next_list
  end
  straight(b, 1)
end

-- n -> m. When m = m' 2^k with m' >= n, an n -> m' balancer followed by
-- 1 -> 2^k splitter trees is much smaller than an m-wide core, and still
-- exact: every input spreads evenly over the m' belts, each of which is
-- split evenly again.
local function build(n, m, ug_max)
  local k, mp = 0, m
  while mp % 2 == 0 and mp / 2 >= n and mp / 2 >= 2 do mp, k = mp / 2, k + 1 end
  if k == 0 then return build_core(n, m, ug_max) end
  local b = build_core(n, mp, ug_max)
  trees(b, k)
  return b
end

local cache = {}

-- Returns a template table for n -> m, or nil, reason.
function gen.template(n, m, ug_max)
  ug_max = math.min(ug_max or 5, 64)
  if n < 1 or m < 1 or n > gen.MAX or m > gen.MAX or ug_max < 2 then return nil end
  local k = n .. "x" .. m .. "@" .. ug_max
  if cache[k] == nil then
    local ok, b = pcall(build, n, m, ug_max)
    if ok then
      cache[k] = {
        name = "generated",
        generated = true,
        inputs = n, outputs = m,
        note = n .. " → " .. m .. " balancer (generated)",
        grid = to_grid(b),
      }
    else
      cache[k] = false
      gen.last_error = b
    end
  end
  return cache[k] or nil
end

return gen
