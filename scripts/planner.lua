-- Pure planning logic: no Factorio API calls in here, so it can be tested
-- outside the game (see tools/test_planner.py).
--
-- Coordinates are integer tile positions; directions are 0=N 1=E 2=S 3=W.
--
-- planner.plan(world) where world = {
--   area      = {x1=, y1=, x2=, y2=}   inclusive tile bounds the build must fit in
--   entities  = { ent, ... }           everything overlapping the area (+1 margin)
--               ent = {kind="belt"|"ug"|"splitter"|"other", tiles={{x,y},..},
--                      dir=0..3, io="in"|"out" (ug only), speed=number}
--   ug_spans  = { {x=,y=,axis=0|1}, ... } tiles crossed by existing underground pairs
--   blocked   = function(x, y) -> true if a belt cannot be placed (terrain, ...),
--               false if free, or a number: buildable after clearing trees,
--               rocks or cliffs there, at that extra cost
--   templates = <templates.lua table>; counts without a template are built
--               by scripts/generator.lua
--   ug_max    = max underground distance of the chosen tier
--   budget    = optional {candidates=, successes=, work=}
-- }
--
-- Returns plan or nil, reason (a locale key + params table).
-- plan = { template=<tpl>, entities={ {kind=, x=, y=, dir=, io=, replace=}... },
--          n_in=, n_out=, cost=, clear={ {x=, y=}... } }
-- Splitters in the result use x,y of their LEFT half tile and carry x2,y2.
-- replace = true: the entity replaces the existing input end / output start
-- belt on that tile (an underground with the belt's direction).
-- clear: tiles under new entities that need trees, rocks or cliffs removed.

local generator = require("scripts.generator")

local planner = {}

local DX = {[0] = 0, 1, 0, -1}
local DY = {[0] = -1, 0, 1, 0}
local function opp(d) return (d + 2) % 4 end
local function left(d) return (d + 3) % 4 end
local function right(d) return (d + 1) % 4 end

-- Numeric tile keys (safe for |coord| < 2^23).
local OFF, MUL = 8388608, 16777216
local function key(x, y) return (x + OFF) * MUL + (y + OFF) end

----------------------------------------------------------------- templates

local UGSYM = {D = {0, "in"}, U = {0, "out"}, e = {1, "in"}, E = {1, "out"},
               d = {2, "in"}, u = {2, "out"}, w = {3, "in"}, W = {3, "out"}}
local BELTSYM = {["^"] = 0, [">"] = 1, ["v"] = 2, ["<"] = 3}

local function split_cells(row)
  local cells = {}
  for c in row:gmatch("%S+") do cells[#cells + 1] = c end
  return cells
end

-- Parse a template grid into local entities (north-flowing frame).
local function parse_template(tpl)
  local ents, inputs, outputs = {}, {}, {}
  local h = #tpl.grid
  local w = 0
  local rows = {}
  for y, row in ipairs(tpl.grid) do rows[y] = split_cells(row) end
  local function at(x, y) return rows[y] and rows[y][x] end
  for y, row in ipairs(tpl.grid) do
    local cells = rows[y]
    if #cells > w then w = #cells end
    local x = 1
    while x <= #cells do
      local c = cells[x]
      local lx, ly = x - 1, y - 1
      if BELTSYM[c] then
        ents[#ents + 1] = {kind = "belt", x = lx, y = ly, dir = BELTSYM[c]}
      elseif UGSYM[c] then
        ents[#ents + 1] = {kind = "ug", x = lx, y = ly, dir = UGSYM[c][1], io = UGSYM[c][2]}
      elseif c == "S" then
        assert(cells[x + 1] == "s", tpl.name .. ": S without s")
        ents[#ents + 1] = {kind = "splitter", x = lx, y = ly, x2 = lx + 1, y2 = ly, dir = 0}
        x = x + 1
      elseif c == "K" then
        -- facing east: K = left (north) half, k right below it
        assert(at(x, y + 1) == "k", tpl.name .. ": K without k below")
        ents[#ents + 1] = {kind = "splitter", x = lx, y = ly, x2 = lx, y2 = ly + 1, dir = 1}
      elseif c == "J" then
        -- facing west: J = left (south) half, j right above it
        assert(at(x, y - 1) == "j", tpl.name .. ": J without j above")
        ents[#ents + 1] = {kind = "splitter", x = lx, y = ly, x2 = lx, y2 = ly - 1, dir = 3}
      elseif c == "Q" then
        -- facing south: Q = left (east) half, q right left of it
        assert(cells[x - 1] == "q", tpl.name .. ": Q without q on its left")
        ents[#ents + 1] = {kind = "splitter", x = lx, y = ly, x2 = lx - 1, y2 = ly, dir = 2}
      elseif c ~= "." and c ~= "k" and c ~= "j" and c ~= "q" then
        error(tpl.name .. ": unknown template symbol " .. c)
      end
      x = x + 1
    end
  end
  for i, e in ipairs(ents) do
    if e.kind == "belt" and e.y == h - 1 then e.port = "in"; inputs[#inputs + 1] = i end
    if e.kind == "belt" and e.y == 0 then e.port = "out"; outputs[#outputs + 1] = i end
  end
  return {ents = ents, inputs = inputs, outputs = outputs, w = w, h = h}
end

-- Mirror (m=1) then rotate clockwise k times, normalised to (0,0).
local function transform(parsed, k, m)
  local out = {}
  local minx, miny = math.huge, math.huge
  local function tf(x, y)
    if m == 1 then x = parsed.w - 1 - x end
    for _ = 1, k do x, y = -y - 1, x end
    return x, y
  end
  local function tdir(d)
    if m == 1 then d = (4 - d) % 4 end
    return (d + k) % 4
  end
  for i, e in ipairs(parsed.ents) do
    local n = {kind = e.kind, dir = tdir(e.dir), io = e.io, port = e.port}
    n.x, n.y = tf(e.x, e.y)
    if e.kind == "splitter" then
      n.x2, n.y2 = tf(e.x2, e.y2)
      -- keep x,y as the LEFT half (relative to facing direction)
      local lx, ly = n.x2 + DX[left(n.dir)], n.y2 + DY[left(n.dir)]
      if not (lx == n.x and ly == n.y) then
        n.x, n.y, n.x2, n.y2 = n.x2, n.y2, n.x, n.y
      end
    end
    out[i] = n
    minx = math.min(minx, n.x, n.x2 or n.x)
    miny = math.min(miny, n.y, n.y2 or n.y)
  end
  for _, n in ipairs(out) do
    n.x, n.y = n.x - minx, n.y - miny
    if n.x2 then n.x2, n.y2 = n.x2 - minx, n.y2 - miny end
  end
  local w, h = parsed.w, parsed.h
  if k % 2 == 1 then w, h = h, w end
  return {ents = out, inputs = parsed.inputs, outputs = parsed.outputs,
          w = w, h = h, flow = k, mirror = m}
end

-- Derived geometry for a placed variant (relative coords):
--   tiles: every occupied tile
--   keep_clear: tiles template entities push into that are not template
--               tiles and not output-port fronts (blocked splitter outputs)
--   spans: tiles crossed by template undergrounds {x,y,axis}
--   ugends: tiles of template undergrounds {x,y,axis}
--   ug_len: longest underground distance
local function analyse(var)
  local occ, tiles = {}, {}
  local function mark(x, y, i)
    occ[key(x, y)] = i
    tiles[#tiles + 1] = {x, y}
  end
  for i, e in ipairs(var.ents) do
    mark(e.x, e.y, i)
    if e.x2 then mark(e.x2, e.y2, i) end
  end
  local keep, spans, ugends, ug_len = {}, {}, {}, 0
  for _, e in ipairs(var.ents) do
    if e.kind == "ug" then ugends[#ugends + 1] = {e.x, e.y, e.dir % 2} end
    local pushes = {}
    if e.kind == "belt" and e.port ~= "out" then pushes[1] = {e.x, e.y}
    elseif e.kind == "ug" and e.io == "out" then pushes[1] = {e.x, e.y}
    elseif e.kind == "splitter" then pushes = {{e.x, e.y}, {e.x2, e.y2}} end
    for _, p in ipairs(pushes) do
      local fx, fy = p[1] + DX[e.dir], p[2] + DY[e.dir]
      if not occ[key(fx, fy)] then keep[#keep + 1] = {fx, fy} end
    end
    if e.kind == "ug" and e.io == "in" then
      for dist = 1, 64 do
        local qx, qy = e.x + DX[e.dir] * dist, e.y + DY[e.dir] * dist
        local o = occ[key(qx, qy)] and var.ents[occ[key(qx, qy)]]
        if o and o.kind == "ug" and o.io == "out" and o.dir == e.dir then
          if dist > ug_len then ug_len = dist end
          break
        end
        spans[#spans + 1] = {qx, qy, e.dir % 2}
      end
    end
  end
  var.tiles, var.keep, var.spans, var.ug_len, var.occ = tiles, keep, spans, ug_len, occ
  var.ugends = ugends
  return var
end

local variant_cache = setmetatable({}, {__mode = "k"})
local function variants_of(tpl)
  if variant_cache[tpl] then return variant_cache[tpl] end
  local parsed = parse_template(tpl)
  local list = {}
  for k = 0, 3 do
    for m = 0, 1 do list[#list + 1] = analyse(transform(parsed, k, m)) end
  end
  variant_cache[tpl] = list
  return list
end
planner._variants_of = variants_of

------------------------------------------------------------------- world

local function is_belt_like(e) return e.kind == "belt" or e.kind == "ug" or e.kind == "splitter" end

-- Tiles an entity pushes items into.
local function push_tiles(e)
  if e.kind == "belt" or (e.kind == "ug" and e.io == "out") then
    local t = e.tiles[1]
    return {{t[1] + DX[e.dir], t[2] + DY[e.dir]}}
  elseif e.kind == "splitter" then
    local r = {}
    for _, t in ipairs(e.tiles) do r[#r + 1] = {t[1] + DX[e.dir], t[2] + DY[e.dir]} end
    return r
  end
  return {}
end

local function index_world(world)
  local occ, fed = {}, {}
  for _, e in ipairs(world.entities) do
    for _, t in ipairs(e.tiles) do occ[key(t[1], t[2])] = e end
    if is_belt_like(e) then
      for _, p in ipairs(push_tiles(e)) do
        local kk = key(p[1], p[2])
        fed[kk] = fed[kk] or {}
        table.insert(fed[kk], e)
      end
    end
  end
  local spans = {}
  for _, s in ipairs(world.ug_spans or {}) do spans[key(s.x, s.y)] = (spans[key(s.x, s.y)] or "") .. s.axis end
  world._occ, world._fed, world._spans = occ, fed, spans
end

local function in_area(a, x, y) return x >= a.x1 and x <= a.x2 and y >= a.y1 and y <= a.y2 end

-- Does the belt chain through `e` reach a tile outside the area, walking
-- upstream (dir = -1) or downstream (dir = 1)?
local function chain_leaves(world, e, way)
  local occ, fed, a = world._occ, world._fed, world.area
  local seen, stack = {[e] = true}, {e}
  local steps = 0
  while #stack > 0 and steps < 4096 do
    steps = steps + 1
    local cur = table.remove(stack)
    for _, t in ipairs(cur.tiles) do
      if not in_area(a, t[1], t[2]) then return true end
    end
    local nexts = {}
    if way < 0 then
      for _, t in ipairs(cur.tiles) do
        for _, f in ipairs(fed[key(t[1], t[2])] or {}) do nexts[#nexts + 1] = f end
      end
      if cur.kind == "ug" and cur.io == "out" and cur.partner then
        if not in_area(a, cur.partner[1], cur.partner[2]) then return true end
        nexts[#nexts + 1] = occ[key(cur.partner[1], cur.partner[2])]
      end
    else
      if cur.kind == "ug" and cur.io == "in" then
        if cur.partner then
          if not in_area(a, cur.partner[1], cur.partner[2]) then return true end
          nexts[#nexts + 1] = occ[key(cur.partner[1], cur.partner[2])]
        end
      else
        for _, p in ipairs(push_tiles(cur)) do
          if not in_area(a, p[1], p[2]) then return true end
          nexts[#nexts + 1] = occ[key(p[1], p[2])]
        end
      end
    end
    for _, nx in ipairs(nexts) do
      if nx and is_belt_like(nx) and not seen[nx] then
        seen[nx] = true
        stack[#stack + 1] = nx
      end
    end
  end
  return false
end

local function centroid(list, fx, fy)
  local sx, sy = 0, 0
  for _, p in ipairs(list) do sx, sy = sx + p[fx], sy + p[fy] end
  return sx / #list, sy / #list
end

-- Find dangling belt ends (inputs) and starts (outputs) inside the area.
--
-- A belt that comes in from outside and ends inside is an input; one that
-- starts inside and leaves is an output. Belt pieces lying completely
-- inside (a single belt or a short chain, start and end both inside) are
-- used too: a piece with more of the other belts ahead of it than behind it
-- is an input, otherwise an output. Pieces that can't be paired up into one
-- start and one end are ignored (counted in `ignored`).
function planner.detect(world)
  if not world._occ then index_world(world) end
  local occ, fed, a = world._occ, world._fed, world.area
  local inputs, outputs, ignored = {}, {}, 0
  local loose_ends, loose_starts = {}, {}
  local function as_input(e)
    local t = e.tiles[1]
    inputs[#inputs + 1] = {ent = e, x = t[1], y = t[2], dir = e.dir,
                           sx = t[1] + DX[e.dir], sy = t[2] + DY[e.dir], speed = e.speed}
  end
  local function as_output(e)
    local t = e.tiles[1]
    outputs[#outputs + 1] = {ent = e, x = t[1], y = t[2], dir = e.dir,
                             side_ok = e.kind == "belt", speed = e.speed}
  end
  for _, e in ipairs(world.entities) do
    if (e.kind == "belt" or e.kind == "ug") then
      local t = e.tiles[1]
      if in_area(a, t[1], t[2]) then
        local fx, fy = t[1] + DX[e.dir], t[2] + DY[e.dir]
        local front = occ[key(fx, fy)]
        local has_consumer = (e.kind == "ug" and e.io == "in") or (front ~= nil and is_belt_like(front))
        local has_feeder = (e.kind == "ug" and e.io == "out") or (fed[key(t[1], t[2])] ~= nil)
        local can_in = (e.kind == "belt" or e.io == "out") and not has_consumer and front == nil
        local can_out = (e.kind == "belt" or e.io == "in") and not has_feeder
        if can_in then
          if chain_leaves(world, e, -1) then as_input(e)
          else loose_ends[#loose_ends + 1] = e end
        end
        if can_out then
          if chain_leaves(world, e, 1) then as_output(e)
          else loose_starts[#loose_starts + 1] = e end
        end
      end
    end
  end

  -- pair every loose start with the loose end its belt leads to
  local is_end = {}
  for _, e in ipairs(loose_ends) do is_end[e] = true end
  local pieces, starts_of = {}, {}
  for _, s in ipairs(loose_starts) do
    local cur, steps = s, 0
    while cur and not is_end[cur] and steps < 4096 do
      steps = steps + 1
      local nxt
      if cur.kind == "ug" and cur.io == "in" then
        nxt = cur.partner and occ[key(cur.partner[1], cur.partner[2])]
      else
        local p = push_tiles(cur)[1]
        nxt = occ[key(p[1], p[2])]
      end
      if nxt and nxt.kind ~= "belt" and nxt.kind ~= "ug" then nxt = nil end
      cur = nxt
    end
    if cur and is_end[cur] then
      if not starts_of[cur] then
        starts_of[cur] = {}
        pieces[#pieces + 1] = cur
      end
      table.insert(starts_of[cur], s)
    else
      ignored = ignored + 1
    end
  end
  local paired = {}
  for _, e in ipairs(pieces) do paired[e] = true end
  for _, e in ipairs(loose_ends) do if not paired[e] then ignored = ignored + 1 end end

  -- classify pieces: count belts ahead of / behind each piece's end
  local loose = {}
  for _, e in ipairs(pieces) do
    if #starts_of[e] == 1 then
      local s = starts_of[e][1]
      local te, ts = e.tiles[1], s.tiles[1]
      loose[#loose + 1] = {e = e, s = s, x = te[1], y = te[2], dir = e.dir,
                           mx = (te[1] + ts[1]) / 2, my = (te[2] + ts[2]) / 2}
    else
      ignored = ignored + #starts_of[e]   -- several belts merging: unclear
    end
  end
  if #loose == 0 then return inputs, outputs, ignored end
  local points = {}
  for _, i in ipairs(inputs) do points[#points + 1] = {x = i.x, y = i.y} end
  for _, o in ipairs(outputs) do points[#points + 1] = {x = o.x, y = o.y} end
  for _, p in ipairs(loose) do points[#points + 1] = {x = p.mx, y = p.my, piece = p} end
  local undecided = {}
  for _, p in ipairs(loose) do
    local score = 0
    for _, q in ipairs(points) do
      if q.piece ~= p then
        local ahead = (q.x - p.x) * DX[p.dir] + (q.y - p.y) * DY[p.dir]
        if ahead >= 0.5 then score = score + 1 elseif ahead <= -0.5 then score = score - 1 end
      end
    end
    if score > 0 then as_input(p.e)
    elseif score < 0 then as_output(p.s)
    else undecided[#undecided + 1] = p end
  end
  -- nothing ahead or behind (e.g. side by side): fill the missing side,
  -- else join the nearer group
  for _, p in ipairs(undecided) do
    if #inputs == 0 then as_input(p.e)
    elseif #outputs == 0 then as_output(p.s)
    else
      local icx, icy = centroid(inputs, "x", "y")
      local ocx, ocy = centroid(outputs, "x", "y")
      if math.abs(p.mx - icx) + math.abs(p.my - icy) <= math.abs(p.mx - ocx) + math.abs(p.my - ocy) then
        as_input(p.e)
      else
        as_output(p.s)
      end
    end
  end
  return inputs, outputs, ignored
end

------------------------------------------------------------------ routing

-- Binary min-heap keyed by .f
local function heap_push(h, n)
  h[#h + 1] = n
  local i = #h
  while i > 1 do
    local p = math.floor(i / 2)
    if h[p].f <= h[i].f then break end
    h[p], h[i] = h[i], h[p]
    i = p
  end
end
local function heap_pop(h)
  local top = h[1]
  local last = table.remove(h)
  if #h > 0 then
    h[1] = last
    local i = 1
    while true do
      local l, r, s = 2 * i, 2 * i + 1, i
      if l <= #h and h[l].f < h[s].f then s = l end
      if r <= #h and h[r].f < h[s].f then s = r end
      if s == i then break end
      h[s], h[i] = h[i], h[s]
      i = s
    end
  end
  return top
end

local TURN_COST = 0.6
-- per input port of a design left unused (prefer 2 -> 4 over 4 -> 4 for 2 inputs)
local UNUSED_PORT_COST = 10
-- extra cost of an underground pair over plain belts on the same tiles
local UG_COST = 1.5
-- extra cost of replacing an input end / output start belt by an underground
local REPLACE_COST = 3
-- slightly over 1: breaks ties between equal-cost tiles towards the goal,
-- which keeps A* from flooding open ground
local H_WEIGHT = 1.001

-- job = {sx, sy, sdir, tx, ty, tdir, side_ok,
--        ug_start = {x, y} or nil   input end belt that may become an entrance
--        ug_end = bool}             output start belt may become an exit
-- ctx = {passable = fn(x, y) -> bool (hard constraint),
--        tilecost = fn(kk) -> cost >= 1 of a belt on tile kk (optional),
--        ug = nil or {max = n, end_ok = fn(x, y, axis), pass_ok = fn(x, y, axis),
--                     cost = fn(kk, axis) -> extra cost of an underground over kk}}
-- Returns a list of {x, y, dir, kind = "belt"|"ug", io = "in"|"out",
-- replace = true for a replaced input/output belt} (may be empty) or nil.
-- Resumable: A holds the search (pass {} to start); with `limit`, at most
-- that many nodes are expanded per call and "pause" is returned when the
-- search isn't finished yet (call again with the same A).
local function route(job, ctx, max_nodes, work, A, limit)
  A = A or {}
  local passable, tilecost, ug = ctx.passable, ctx.tilecost, ctx.ug
  local function entry_ok(d)
    return d == job.tdir or (job.side_ok and d ~= opp(job.tdir))
  end
  if job.sx == job.tx and job.sy == job.ty then
    return entry_ok(job.sdir) and {} or nil
  end
  local tk = key(job.tx, job.ty)
  local function hdist(x, y) return math.abs(x - job.tx) + math.abs(y - job.ty) end
  local function skey(kk, din, exit) return kk * 8 + din * 2 + (exit and 1 or 0) end

  local fresh = A.open == nil
  if fresh then A.open, A.best, A.closed, A.expanded = {}, {}, {}, 0 end
  local open, best, closed = A.open, A.best, A.closed
  local function push(n)
    local sk = skey(key(n.x, n.y), n.din, n.exit)
    if best[sk] and best[sk] <= n.g then return end
    best[sk] = n.g
    n.f = n.g + H_WEIGHT * hdist(n.x, n.y)
    heap_push(open, n)
  end
  if fresh then
    if passable(job.sx, job.sy) then
      local c0 = tilecost and tilecost(key(job.sx, job.sy)) or 1
      push({x = job.sx, y = job.sy, din = job.sdir, g = c0})
    end
    if ug and job.ug_start then
      -- the input end itself becomes an underground entrance (same direction)
      push({x = job.ug_start[1], y = job.ug_start[2], din = job.sdir, g = REPLACE_COST,
            only_jump = true, replace = true})
    end
  end

  local this_call = 0
  while #open > 0 do
    if limit and this_call >= limit then return "pause" end
    local n = heap_pop(open)
    if n.goal then
      local chain = {}
      local cur = n.parent
      while cur do table.insert(chain, 1, cur); cur = cur.parent end
      local path = {}
      for i, c in ipairs(chain) do
        local nxt = chain[i + 1] or n
        local e = {x = c.x, y = c.y}
        if c.exit then
          e.kind, e.io, e.dir = "ug", "out", c.din
        elseif nxt.via == "ug" then
          e.kind, e.io, e.dir, e.replace = "ug", "in", nxt.din, c.replace
        else
          e.kind, e.dir = "belt", nxt.din
        end
        path[#path + 1] = e
      end
      if n.via == "ug" then
        path[#path + 1] = {x = job.tx, y = job.ty, kind = "ug", io = "out", dir = job.tdir, replace = true}
      end
      return path
    end
    local sk = skey(key(n.x, n.y), n.din, n.exit)
    if not closed[sk] then
      closed[sk] = true
      A.expanded = A.expanded + 1
      this_call = this_call + 1
      if A.expanded > max_nodes then return nil end
      if work then
        work.n = work.n - 1
        if work.n <= 0 then return nil end
      end
      for d = 0, 3 do
        if d ~= opp(n.din) and not (n.exit and d ~= n.din) then
          -- plain belt step
          if not n.only_jump then
            local qx, qy = n.x + DX[d], n.y + DY[d]
            local qk = key(qx, qy)
            local turn = (d ~= n.din) and TURN_COST or 0
            if qk == tk then
              if entry_ok(d) then
                heap_push(open, {goal = true, via = "belt", din = d, parent = n,
                                 g = n.g + turn, f = n.g + turn})
              end
            elseif passable(qx, qy) then
              push({x = qx, y = qy, din = d, parent = n, via = "belt",
                    g = n.g + (tilecost and tilecost(qk) or 1) + turn})
            end
          end
          -- underground: entrance on this tile, fed straight from behind
          if ug and d == n.din and not n.exit and ug.end_ok(n.x, n.y, d % 2) then
            local axis = d % 2
            local extra = ug.cost(key(n.x, n.y), axis)
            for k = 1, ug.max do
              local qx, qy = n.x + DX[d] * k, n.y + DY[d] * k
              local qk = key(qx, qy)
              extra = extra + ug.cost(qk, axis)
              if k >= 2 then
                local g = n.g + UG_COST + (k - 1) + extra
                if qk == tk then
                  if job.ug_end and d == job.tdir and ug.end_ok(qx, qy, axis) then
                    g = g + REPLACE_COST
                    heap_push(open, {goal = true, via = "ug", din = d, parent = n, g = g, f = g})
                  end
                elseif passable(qx, qy) and ug.end_ok(qx, qy, axis) then
                  push({x = qx, y = qy, din = d, exit = true, parent = n, via = "ug",
                        g = g + (tilecost and tilecost(qk) or 1)})
                end
              end
              -- going further means passing under this tile
              if qk == tk or not ug.pass_ok(qx, qy, axis) then break end
            end
          end
        end
      end
    end
  end
  return nil
end
planner._route = route

---------------------------------------------------------------- placement

local function proj(flow, x, y)
  local p = right(flow)
  return x * DX[p] + y * DY[p]
end

local function manhattan(ax, ay, bx, by) return math.abs(ax - bx) + math.abs(ay - by) end

-- Sweep angle of (x, y) seen from (cx, cy), looking along `ahead`:
-- left side < straight ahead (0) < right side; behind wraps to +-pi.
-- Ports sorted left-to-right paired with belts sorted by this angle give
-- non-crossing (nested) routes, also when belts leave sideways.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local function sweep(ahead, cx, cy, x, y)
  local r = right(ahead)
  local dx, dy = x - cx, y - cy
  local side = dx * DX[r] + dy * DY[r]
  local fwd = dx * DX[ahead] + dy * DY[ahead]
  return atan2(side, fwd + 0.5)
end


-- Choose which template input ports the n inputs use (contiguous window,
-- in projection order) and pair them; returns pairs, cost.
local function assign_inputs(ins, ports, flow)
  local cx, cy = centroid(ports, "x", "y")
  local back = opp(flow)
  -- looking upstream, "left" is the template's right: negate to keep order
  local si = {}
  for i, v in ipairs(ins) do si[i] = v; v._a = -sweep(back, cx, cy, v.sx, v.sy) end
  table.sort(si, function(a, b) return a._a < b._a end)
  local sp = {}
  for i, v in ipairs(ports) do sp[i] = v end
  table.sort(sp, function(a, b) return proj(flow, a.x, a.y) < proj(flow, b.x, b.y) end)
  local best, best_cost
  for off = 0, #sp - #si do
    local cost, pairs = 0, {}
    for i, inp in ipairs(si) do
      local p = sp[off + i]
      cost = cost + manhattan(inp.sx, inp.sy, p.x, p.y)
      pairs[i] = {inp, p}
    end
    if not best_cost or cost < best_cost then best, best_cost = pairs, cost end
  end
  return best, best_cost
end

local function assign_outputs(outs, ports, flow)
  local cx, cy = centroid(ports, "fx", "fy")
  local so = {}
  for i, v in ipairs(outs) do so[i] = v; v._a = sweep(flow, cx, cy, v.x, v.y) end
  table.sort(so, function(a, b) return a._a < b._a end)
  local sp = {}
  for i, v in ipairs(ports) do sp[i] = v end
  table.sort(sp, function(a, b) return proj(flow, a.fx, a.fy) < proj(flow, b.fx, b.fy) end)
  local pairs, cost = {}, 0
  for i, o in ipairs(so) do
    pairs[i] = {sp[i], o}
    cost = cost + manhattan(sp[i].fx, sp[i].fy, o.x, o.y)
  end
  return pairs, cost
end

------------------------------------------------------------- candidates
--
-- Everything below is resumable: a search keeps its state in plain tables
-- (no functions), so control.lua can keep it in `storage` and spread the
-- work over several ticks. Callbacks into the game (`blocked`) are passed
-- in on every step instead of being stored.

-- Routing state for one placed candidate, or nil if it can't work at all.
-- use_ug: routes may use underground belts.
local function cand_init(world, cand, use_ug)
  local var, ox, oy = cand.var, cand.ox, cand.oy
  local tocc = {}
  for _, t in ipairs(var.tiles) do tocc[key(t[1] + ox, t[2] + oy)] = true end
  for _, t in ipairs(var.keep) do tocc[key(t[1] + ox, t[2] + oy)] = true end

  -- unused input ports are not built; their tiles become ordinary ground
  local used_port = {}
  for _, pr in ipairs(cand.in_pairs) do used_port[pr[2].idx] = true end
  for idx in pairs(cand.preset_in or {}) do used_port[idx] = true end
  for _, idx in ipairs(var.inputs) do
    if not used_port[idx] then
      local e = var.ents[idx]
      tocc[key(e.x + ox, e.y + oy)] = nil
    end
  end

  -- lines of the template's own undergrounds
  local tspan = {}
  for _, list in ipairs({var.spans, var.ugends}) do
    for _, s in ipairs(list) do
      local kk = key(s[1] + ox, s[2] + oy)
      tspan[kk] = (tspan[kk] or "") .. s[3]
    end
  end

  -- tiles pushed into by the template that routes must not use
  local tfed = {}
  for _, pr in ipairs(cand.out_pairs) do tfed[key(pr[1].fx, pr[1].fy)] = true end

  local fed = world._fed
  local jobs = {}
  for _, pr in ipairs(cand.in_pairs) do
    local inp, port = pr[1], pr[2]
    -- ug_end: the template's input port may become the exit
    local job = {sx = inp.sx, sy = inp.sy, sdir = inp.dir,
                 tx = port.x, ty = port.y, tdir = var.flow, side_ok = true, ug_end = true,
                 port_end = port.idx}
    -- the input end may become an underground entrance if it is fed
    -- straight from behind
    local f = fed[key(inp.x, inp.y)]
    if inp.ent.kind == "belt" and f and #f == 1 and f[1].dir == inp.dir then
      job.ug_start = {inp.x, inp.y}
    end
    jobs[#jobs + 1] = job
  end
  for _, pr in ipairs(cand.out_pairs) do
    local port, o = pr[1], pr[2]
    -- ug_start: the template's output port may become an entrance (the only
    -- way out when something sits in front of the port)
    if port.blocked and not use_ug then return nil end
    jobs[#jobs + 1] = {sx = port.fx, sy = port.fy, sdir = var.flow, blocked = port.blocked,
                       tx = o.x, ty = o.y, tdir = o.dir, side_ok = o.side_ok,
                       ug_end = o.ent.kind == "belt",
                       ug_start = {port.fx - DX[var.flow], port.fy - DY[var.flow]},
                       port_start = port.idx}
  end
  -- reserve each job's start tile (it is forced: something pushes into it)
  local reserved = {}
  for i, j in ipairs(jobs) do reserved[key(j.sx, j.sy)] = i end

  local order = {}
  for i = 1, #jobs do order[i] = i end
  table.sort(order, function(p, q)
    local jp, jq = jobs[p], jobs[q]
    local dp, dq = manhattan(jp.sx, jp.sy, jp.tx, jp.ty), manhattan(jq.sx, jq.sy, jq.tx, jq.ty)
    if dp ~= dq then return dp < dq end
    return p < q
  end)

  return {cand = cand, use_ug = use_ug, tocc = tocc, used_port = used_port, tspan = tspan,
          tfed = tfed, jobs = jobs, reserved = reserved, order = order,
          iter = 1, oi = 1, present = 0.5, stall = 0,
          usage = {}, history = {}, paths = {},
          ax_use = {[0] = {}, [1] = {}}, ax_hist = {[0] = {}, [1] = {}}}
end

-- every (map, key) a path claims
local function claims(R, path)
  local list = {}
  for i, p in ipairs(path) do
    list[#list + 1] = {R.usage, key(p.x, p.y)}
    if p.kind == "ug" and p.io == "in" then
      local q = path[i + 1]
      local axis = p.dir % 2
      local len = math.abs(q.x - p.x) + math.abs(q.y - p.y)
      for k = 0, len do
        list[#list + 1] = {R.ax_use[axis], key(p.x + DX[p.dir] * k, p.y + DY[p.dir] * k)}
      end
    end
  end
  return list
end

-- Negotiated congestion: route every job, letting them overlap at a price
-- that rises each round, until no tile is shared. Undergrounds also claim
-- their whole line (per axis) so two pairs never interleave.
-- Routes jobs until `tick` work is used. Returns nil (not done yet), false
-- (candidate fails) or true, entities, cost.
local function cand_step(world, R, free, clear_at, tick)
  local cand, jobs = R.cand, R.jobs
  local var, ox, oy = cand.var, cand.ox, cand.oy
  local area = world.area
  local occ, fed, wspans = world._occ, world._fed, world._spans
  local tocc, tspan, tfed, reserved = R.tocc, R.tspan, R.tfed, R.reserved

  local function make_passable(job)
    return function(x, y)
      if not in_area(area, x, y) then return false end
      local kk = key(x, y)
      if tocc[kk] or not free(x, y) then return false end
      if x == job.sx and y == job.sy then return not job.blocked end
      if reserved[kk] then return false end
      if fed[kk] or tfed[kk] then return false end
      return true
    end
  end
  -- an underground may not end on, or pass under, a tile on the line of
  -- another underground with the same axis (it would pair with it)
  local function on_line(kk, axis)
    local a = tostring(axis)
    local w, t = wspans[kk], tspan[kk]
    return (w and w:find(a, 1, true)) or (t and t:find(a, 1, true))
  end
  local function end_ok(x, y, axis) return not on_line(key(x, y), axis) end
  local function pass_ok(x, y, axis)
    if not in_area(area, x, y) then return false end
    local kk = key(x, y)
    local e = occ[kk]
    if e and e.kind == "ug" and e.dir % 2 == axis then return false end
    return not on_line(kk, axis)
  end
  local usage, history = R.usage, R.history
  local function tilecost(kk)
    local u = usage[kk] or 0
    return (1 + clear_at(kk) + (history[kk] or 0)) * (1 + R.present * u)
  end
  local ugctx
  if R.use_ug then
    ugctx = {
      max = world.ug_max or 5, end_ok = end_ok, pass_ok = pass_ok,
      cost = function(kk, axis)
        return (R.ax_hist[axis][kk] or 0) + R.present * (R.ax_use[axis][kk] or 0)
      end,
    }
  end

  local max_nodes = world.max_nodes or 12000
  local start = world._work.n
  while true do
    if R.oi > #R.order then
      -- end of a round: count and price the shared tiles
      local nconf = 0
      for _, pair in ipairs({{usage, history}, {R.ax_use[0], R.ax_hist[0]}, {R.ax_use[1], R.ax_hist[1]}}) do
        for kk, u in pairs(pair[1]) do
          if u > 1 then
            nconf = nconf + 1
            pair[2][kk] = (pair[2][kk] or 0) + 1
          end
        end
      end
      if nconf == 0 then break end
      -- give up on this candidate when overlaps stop shrinking
      if not R.best_conf or nconf < R.best_conf then R.best_conf, R.stall = nconf, 0
      else R.stall = R.stall + 1 end
      if R.stall >= 4 then return false end
      R.present = R.present * 1.8
      R.iter, R.oi = R.iter + 1, 1
      if R.iter > (world.route_iterations or 12) then return false end
    else
      local ji = R.order[R.oi]
      if not R.astar then
        -- re-route this job: drop its old claims first
        local old = R.paths[ji]
        if old then
          for _, c in ipairs(claims(R, old)) do c[1][c[2]] = c[1][c[2]] - 1 end
        end
        R.astar = {}
      end
      local ctx = {passable = make_passable(jobs[ji]), tilecost = tilecost, ug = ugctx}
      local left = math.max(1, tick - (start - world._work.n))
      local path = route(jobs[ji], ctx, max_nodes, world._work, R.astar, left)
      if path == "pause" then return nil end
      R.astar = nil
      if not path then return false end   -- unroutable even with overlaps
      R.paths[ji] = path
      for _, c in ipairs(claims(R, path)) do c[1][c[2]] = (c[1][c[2]] or 0) + 1 end
      R.oi = R.oi + 1
      if start - world._work.n >= tick then return nil end
    end
  end

  -- no tile shared: build the entity list
  local n = #jobs
  local paths = R.paths
  -- template ports replaced by a route's underground (or by an existing
  -- belt end) are not built
  local dropped = {}
  for idx in pairs(cand.preset_in or {}) do dropped[idx] = true end
  for idx in pairs(cand.preset_out or {}) do dropped[idx] = true end
  local replace_ok = {}
  for i = 1, n do
    local path, job = paths[i], jobs[i]
    local first, last = path[1], path[#path]
    if job.port_start and first and first.replace then
      dropped[job.port_start] = true
      replace_ok[first] = false
    end
    if job.port_end and last and last.replace then
      dropped[job.port_end] = true
      replace_ok[last] = false
    end
  end
  local ents, cost = {}, 0
  for i, e in ipairs(var.ents) do
    if not (e.port == "in" and not R.used_port[i]) and not dropped[i] then
      local r = {kind = e.kind, x = e.x + ox, y = e.y + oy, dir = e.dir, io = e.io}
      if e.x2 then r.x2, r.y2 = e.x2 + ox, e.y2 + oy end
      ents[#ents + 1] = r
    end
  end
  for i = 1, n do
    local path = paths[i]
    for pi, p in ipairs(path) do
      local replace = p.replace
      if replace_ok[p] == false then replace = nil end
      ents[#ents + 1] = {kind = p.kind, x = p.x, y = p.y, dir = p.dir, io = p.io,
                         replace = replace, route = i}
      cost = cost + 1 + clear_at(key(p.x, p.y))
      if p.kind == "ug" and p.io == "in" then cost = cost + UG_COST end
      if pi > 1 and path[pi - 1].dir ~= p.dir then cost = cost + TURN_COST end
    end
  end
  return true, ents, cost
end

------------------------------------------------------------------ search

-- world.blocked(x, y) / the `blocked` passed to a step: true = can't build,
-- false = free, a number = can build after clearing (trees, rocks,
-- cliffs), at that extra cost. Answers are cached in the search.
local function lookups(S, blocked)
  local occ, bc = S.world._occ, S.bc
  local function free(x, y)
    local kk = key(x, y)
    if occ[kk] then return false end
    local b = bc[kk]
    if b == nil then
      b = blocked and blocked(x, y) or false
      bc[kk] = b
    end
    return b ~= true
  end
  local function clear_at(kk)
    local b = bc[kk]
    return type(b) == "number" and b or 0
  end
  return free, clear_at
end

-- A search for the given belt ends; nil, reason if no design exists.
local function search_new(world, inputs, outputs)
  local n, m = #inputs, #outputs
  -- candidate templates: hand-drawn ones, else a generated design
  local tpls = {}
  local want_lane = (n == 1 and m == 1)
  for _, t in ipairs(world.templates) do
    -- exact: only balanced with every input in use
    if t.outputs == m and t.inputs >= n and (t.lane or false) == want_lane
       and not (t.exact and t.inputs ~= n) then
      tpls[#tpls + 1] = t
    end
  end
  if #tpls == 0 and not want_lane then
    tpls[1] = generator.template(n, m, world.ug_max or 5)
  end
  if #tpls == 0 then return nil, {"lbb.no-template", n, m, generator.MAX} end

  -- majority input direction is the preferred flow direction
  local dir_votes = {[0] = 0, [1] = 0, [2] = 0, [3] = 0}
  for _, i in ipairs(inputs) do dir_votes[i.dir] = dir_votes[i.dir] + 1 end
  local input_start, input_end, output_tile = {}, {}, {}
  for _, i in ipairs(inputs) do
    input_start[key(i.sx, i.sy)] = i
    input_end[key(i.x, i.y)] = i
  end
  for _, o in ipairs(outputs) do output_tile[key(o.x, o.y)] = o end
  local icx, icy = centroid(inputs, "sx", "sy")
  local ocx, ocy = centroid(outputs, "x", "y")
  local budget = world.budget or {}
  world._work = {n = budget.work or 300000}
  return {world = world, inputs = inputs, outputs = outputs, n = n, m = m, tpls = tpls,
          bc = {}, phase = "scan", ti = 1, vi = 1, cands = {},
          dir_votes = dir_votes, input_start = input_start, input_end = input_end,
          output_tile = output_tile, icx = icx, icy = icy, ocx = ocx, ocy = ocy,
          route_ug = (world.ug_max or 5) >= 2 and not world.no_route_ug,
          max_c = budget.candidates or 40, max_s = budget.successes or 3}
end

-- Port centroids of a variant (cached on the variant).
local function port_centres(var)
  if var.in_cx then return end
  local ip, op = {}, {}
  for _, idx in ipairs(var.inputs) do local e = var.ents[idx]; ip[#ip + 1] = {x = e.x, y = e.y} end
  for _, idx in ipairs(var.outputs) do
    local e = var.ents[idx]
    op[#op + 1] = {x = e.x + DX[e.dir], y = e.y + DY[e.dir]}
  end
  var.in_cx, var.in_cy = centroid(ip, "x", "y")
  var.out_cx, var.out_cy = centroid(op, "x", "y")
end

-- Can variant `var` sit at (ox, oy)? Adds a candidate if so.
local function try_place(S, var, ox, oy, free, clear_at)
  local world, a = S.world, S.world.area
  local occ, fed, spans = world._occ, world._fed, world._spans
  local input_start, input_end, output_tile = S.input_start, S.input_end, S.output_tile
  -- a port may sit on an existing input end / output start facing the same
  -- way: that belt is the port, nothing is built there
  local preset_in, preset_out, preset_at, preset_feed = {}, {}, {}, {}
  for _, idx in ipairs(var.inputs) do
    local e = var.ents[idx]
    local kk = key(e.x + ox, e.y + oy)
    local inp = input_end[kk]
    if inp and inp.dir == var.flow then
      preset_in[idx], preset_at[kk] = inp, true
      preset_feed[key(inp.sx, inp.sy)] = true
    end
  end
  for _, idx in ipairs(var.outputs) do
    local e = var.ents[idx]
    local kk = key(e.x + ox, e.y + oy)
    local o = output_tile[kk]
    if o and o.dir == var.flow then preset_out[idx], preset_at[kk] = o, true end
  end
  for _, t in ipairs(var.tiles) do
    local x, y = t[1] + ox, t[2] + oy
    local kk = key(x, y)
    if not preset_at[kk] then
      if not free(x, y) then return end
      if fed[kk] and not (preset_feed[kk] and #fed[kk] == 1) then
        -- only an input end may push straight into a template tile
        local e = var.ents[var.occ[key(t[1], t[2])]]
        if not (e.port == "in" and input_start[kk] and #fed[kk] == 1) then return end
      end
    end
  end
  for _, t in ipairs(var.keep) do
    local x, y = t[1] + ox, t[2] + oy
    if not in_area(a, x, y) or not free(x, y) then return end
  end
  for _, s in ipairs(var.spans) do
    local sp = spans[key(s[1] + ox, s[2] + oy)]
    local here = occ[key(s[1] + ox, s[2] + oy)]
    if (sp and sp:find(tostring(s[3]), 1, true)) or
       (here and here.kind == "ug" and here.dir % 2 == s[3]) then return end
  end
  -- template undergrounds must not sit on the line of an existing pair
  for _, s in ipairs(var.ugends) do
    local sp = spans[key(s[1] + ox, s[2] + oy)]
    if sp and sp:find(tostring(s[3]), 1, true) then return end
  end
  -- output port fronts must be buildable or be an output start
  local oports = {}
  for _, idx in ipairs(var.outputs) do
    if not preset_out[idx] then
      local e = var.ents[idx]
      local fx, fy = e.x + ox + DX[e.dir], e.y + oy + DY[e.dir]
      local fk = key(fx, fy)
      local blocked_front = false
      if not (output_tile[fk] or (in_area(a, fx, fy) and free(fx, fy) and not fed[fk])) then
        -- something in front: only an underground from the port gets out
        if not S.route_ug then return end
        blocked_front = true
      end
      oports[#oports + 1] = {fx = fx, fy = fy, idx = idx, blocked = blocked_front}
    end
  end
  local iports = {}
  for _, idx in ipairs(var.inputs) do
    if not preset_in[idx] then
      local e = var.ents[idx]
      iports[#iports + 1] = {x = e.x + ox, y = e.y + oy, idx = idx}
    end
  end
  -- cheap estimate; exact pairing is done only for the best few
  local pcx, pcy = var.in_cx + ox, var.in_cy + oy
  local qcx, qcy = var.out_cx + ox, var.out_cy + oy
  local clear = 0
  for _, t in ipairs(var.tiles) do clear = clear + clear_at(key(t[1] + ox, t[2] + oy)) end
  -- a design with spare inputs builds splitters nothing flows through
  clear = clear + (#var.inputs - S.n) * UNUSED_PORT_COST
  local h_cost = S.n * manhattan(S.icx, S.icy, pcx, pcy) + S.m * manhattan(qcx, qcy, S.ocx, S.ocy)
               + (#var.tiles) * 0.3 + (S.n - S.dir_votes[var.flow]) * 2 + clear
  S.cands[#S.cands + 1] = {var = var, ox = ox, oy = oy, tpl = S.tpl_now, clear = clear,
                           iports = iports, oports = oports, h = h_cost,
                           preset_in = preset_in, preset_out = preset_out}
end

-- Placement scan done: rank the candidates (exact pairing for the best few).
local function rank(S)
  local cands = S.cands
  local n = S.n
  table.sort(cands, function(p, q) return p.h < q.h end)
  local top = {}
  for i = 1, math.min(#cands, S.max_c * 3) do
    local c = cands[i]
    -- belt ends serving as ports are already connected
    local used = {}
    for _, v in pairs(c.preset_in) do used[v] = true end
    for _, v in pairs(c.preset_out) do used[v] = true end
    local rin, rout = {}, {}
    for _, v in ipairs(S.inputs) do if not used[v] then rin[#rin + 1] = v end end
    for _, v in ipairs(S.outputs) do if not used[v] then rout[#rout + 1] = v end end
    local ip, icost, op, ocost = {}, 0, {}, 0
    if #rin > 0 then ip, icost = assign_inputs(rin, c.iports, c.var.flow) end
    if #rout > 0 then op, ocost = assign_outputs(rout, c.oports, c.var.flow) end
    c.in_pairs, c.out_pairs = ip, op
    c.h = icost + ocost + (#c.var.tiles) * 0.3 + (n - S.dir_votes[c.var.flow]) * 2 + c.clear
    top[#top + 1] = c
  end
  table.sort(top, function(p, q) return p.h < q.h end)
  S.cands, S.ci, S.successes = top, 1, 0
end

local function finish(S)
  local best = S.best
  if not best then
    if S.world._work.n <= 0 then S.reason = {"lbb.gave-up", S.n, S.m}
    else S.reason = {"lbb.no-route", S.n, S.m} end
    return true
  end
  local _, clear_at = lookups(S, nil)
  -- tiles that must be cleared (trees, rocks, cliffs) before building
  local clear, seen = {}, {}
  for _, e in ipairs(best) do
    for _, t in ipairs({{e.x, e.y}, e.x2 and {e.x2, e.y2} or nil}) do
      local kk = key(t[1], t[2])
      if not seen[kk] and clear_at(kk) > 0 then
        seen[kk] = true
        clear[#clear + 1] = {x = t[1], y = t[2]}
      end
    end
  end
  local cand = S.best_cand
  S.plan = {template = cand.tpl, entities = best, n_in = S.n, n_out = S.m, cost = S.best_cost,
            flow = cand.var.flow, inputs = S.inputs, outputs = S.outputs, clear = clear}
  return true
end

-- One slice of a search, about `tick` units of work. Returns true when
-- finished (S.plan or S.reason is set).
local function search_step(S, tick, blocked)
  local free, clear_at = lookups(S, blocked)
  local world, a = S.world, S.world.area
  local done = 0
  if S.phase == "scan" then
    while S.ti <= #S.tpls do
      local tpl = S.tpls[S.ti]
      local var = variants_of(tpl)[S.vi]
      if not var then
        S.ti, S.vi, S.ox = S.ti + 1, 1, nil
      elseif var.ug_len > (world.ug_max or 5) then
        S.vi, S.ox = S.vi + 1, nil
      else
        port_centres(var)
        S.ox = S.ox or a.x1
        if S.ox > a.x2 - var.w + 1 then
          S.vi, S.ox = S.vi + 1, nil
        else
          S.tpl_now = tpl
          for oy = a.y1, a.y2 - var.h + 1 do
            try_place(S, var, S.ox, oy, free, clear_at)
            done = done + #var.tiles / 4
          end
          S.ox = S.ox + 1
        end
      end
      if done >= tick then return false end
    end
    if #S.cands == 0 then
      -- smallest design footprint (narrow side x long side)
      local dw, dh
      for _, tpl in ipairs(S.tpls) do
        local v = variants_of(tpl)[1]
        local s1, s2 = math.min(v.w, v.h), math.max(v.w, v.h)
        if not dw or s1 * s2 < dw * dh then dw, dh = s1, s2 end
      end
      S.reason = {"lbb.no-room", S.n, S.m, dw, dh}
      return true
    end
    rank(S)
    S.phase = "try"
    if done >= tick then return false end
  end

  -- try the most promising placements: plain belts first, undergrounds
  -- only when belts can't make it
  local start = world._work.n
  while true do
    if not S.run then
      local cand = S.cands[S.ci]
      if not cand or S.ci > S.max_c or world._work.n <= 0
         or (S.best_cost and cand.h > S.best_cost + 8) then
        return finish(S)
      end
      S.run, S.run_ug = cand_init(world, cand, false), false
      if not S.run and S.route_ug then S.run, S.run_ug = cand_init(world, cand, true), true end
      if not S.run then S.ci = S.ci + 1 end
    else
      local remaining = tick - done - (start - world._work.n)
      local ok, ents, cost = cand_step(world, S.run, free, clear_at, math.max(remaining, 1))
      if ok == nil then return false end
      local cand = S.run.cand
      if ok then
        cost = cost + (#cand.var.tiles) * 0.3 + cand.clear
        if not S.best_cost or cost < S.best_cost then
          S.best, S.best_cost, S.best_cand = ents, cost, cand
        end
        S.run, S.ci = nil, S.ci + 1
        -- a placement that needed undergrounds is a fallback: keep looking
        if not S.run_ug then
          S.successes = S.successes + 1
          if S.successes >= S.max_s then return finish(S) end
        end
      elseif not S.run_ug and S.route_ug and world._work.n > 0 then
        S.run, S.run_ug = cand_init(world, cand, true), true
        if not S.run then S.ci = S.ci + 1 end
      else
        S.run, S.ci = nil, S.ci + 1
      end
    end
    if done + (start - world._work.n) >= tick then return false end
  end
end

------------------------------------------------------------------- plan

-- Starts planning. Returns a state for planner.step, or nil, reason when
-- the selection can't work at all.
function planner.start(world)
  index_world(world)
  local a = world.area
  local w, h = a.x2 - a.x1 + 1, a.y2 - a.y1 + 1
  if w > 64 or h > 64 then return nil, {"lbb.too-big", 64} end

  local inputs, outputs = planner.detect(world)
  local n, m = #inputs, #outputs
  if n == 0 or m == 0 then return nil, {"lbb.no-ends", n, m} end
  for _, inp in ipairs(inputs) do
    if not in_area(a, inp.sx, inp.sy) then return nil, {"lbb.input-leaves", inp.x, inp.y} end
  end
  local S, reason = search_new(world, inputs, outputs)
  if not S then return nil, reason end
  return {world = world, inputs = inputs, outputs = outputs, main = S, grow = 0}
end

local HINT_REASONS = {["lbb.no-room"] = true, ["lbb.no-route"] = true, ["lbb.gave-up"] = true}

-- Does about `tick` units of work (one unit ~ one route search node).
-- blocked: the world lookup (see lookups), passed on every call.
-- Returns nil while not done, else the plan, or false, reason, hint.
-- hint = {w, h, grow}: the same belt ends could be connected in a
-- selection grown by `grow` tiles on each side (w x h tiles).
function planner.step(P, tick, blocked)
  if P.main then
    if not search_step(P.main, tick, blocked) then return nil end
    local S = P.main
    P.main = nil
    if S.plan then return S.plan end
    P.reason = S.reason
    if P.world.no_hint or not HINT_REASONS[S.reason[1]] then return false, S.reason end
  end
  -- would a bigger selection do? same belt ends, more ground around them
  local a = P.world.area
  local w, h = a.x2 - a.x1 + 1, a.y2 - a.y1 + 1
  while true do
    if not P.sub then
      P.grow = P.grow + 1
      local g = P.grow
      if g > 3 or w + 2 * g > 64 or h + 2 * g > 64 then return false, P.reason end
      local big = {}
      for k, v in pairs(P.world) do big[k] = v end
      big.area = {x1 = a.x1 - g, y1 = a.y1 - g, x2 = a.x2 + g, y2 = a.y2 + g}
      big.budget = {candidates = 20, successes = 1, work = 60000}
      P.sub = search_new(big, P.inputs, P.outputs)
      if not P.sub then return false, P.reason end
    end
    if not search_step(P.sub, tick, blocked) then return nil end
    local ok = P.sub.plan ~= nil
    P.sub = nil
    if ok then return false, P.reason, {w + 2 * P.grow, h + 2 * P.grow, P.grow} end
  end
end

-- Plans in one go (tests, and anything that doesn't mind the wait).
-- Returns plan, or nil, reason, hint.
function planner.plan(world)
  local P, reason = planner.start(world)
  if not P then return nil, reason end
  while true do
    local res, why, hint = planner.step(P, math.huge, world.blocked)
    if res then return res end
    if res == false then return nil, why, hint end
  end
end

return planner
