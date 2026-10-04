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
               w = {3, "in"}, W = {3, "out"}}
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
  for y, row in ipairs(tpl.grid) do
    local cells = split_cells(row)
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
      elseif c ~= "." then
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

-- Find dangling belt ends (inputs) and starts (outputs) inside the area.
-- Inputs must come from outside the area, outputs must leave it; belt
-- fragments lying fully inside are ignored (counted in `ignored`).
function planner.detect(world)
  if not world._occ then index_world(world) end
  local occ, fed, a = world._occ, world._fed, world.area
  local inputs, outputs, ignored = {}, {}, 0
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
          if chain_leaves(world, e, -1) then
            inputs[#inputs + 1] = {ent = e, x = t[1], y = t[2], dir = e.dir, sx = fx, sy = fy,
                                   speed = e.speed}
          else
            ignored = ignored + 1
          end
        end
        if can_out then
          if chain_leaves(world, e, 1) then
            outputs[#outputs + 1] = {ent = e, x = t[1], y = t[2], dir = e.dir,
                                     side_ok = e.kind == "belt", speed = e.speed}
          else
            ignored = ignored + 1
          end
        end
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
-- extra cost of an underground pair over plain belts on the same tiles
local UG_COST = 1.5
-- extra cost of replacing an input end / output start belt by an underground
local REPLACE_COST = 1
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
local function route(job, ctx, max_nodes, work)
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

  local open, best, closed = {}, {}, {}
  local function push(n)
    local sk = skey(key(n.x, n.y), n.din, n.exit)
    if best[sk] and best[sk] <= n.g then return end
    best[sk] = n.g
    n.f = n.g + H_WEIGHT * hdist(n.x, n.y)
    heap_push(open, n)
  end
  if passable(job.sx, job.sy) then
    local c0 = tilecost and tilecost(key(job.sx, job.sy)) or 1
    push({x = job.sx, y = job.sy, din = job.sdir, g = c0})
  end
  if ug and job.ug_start then
    -- the input end itself becomes an underground entrance (same direction)
    push({x = job.ug_start[1], y = job.ug_start[2], din = job.sdir, g = REPLACE_COST,
          only_jump = true, replace = true})
  end

  local expanded = 0
  while #open > 0 do
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
      expanded = expanded + 1
      if expanded > max_nodes then return nil end
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

local function centroid(list, fx, fy)
  local sx, sy = 0, 0
  for _, p in ipairs(list) do sx, sy = sx + p[fx], sy + p[fy] end
  return sx / #list, sy / #list
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

-- Try to route every job of a placed candidate. Returns entity list, cost
-- or nil. clear_at(kk) -> extra cost of clearing tile kk (trees, rocks).
-- use_ug: routes may use underground belts.
local function try_candidate(world, cand, free, clear_at, use_ug)
  local var, ox, oy = cand.var, cand.ox, cand.oy
  local tocc = {}
  for _, t in ipairs(var.tiles) do tocc[key(t[1] + ox, t[2] + oy)] = true end
  for _, t in ipairs(var.keep) do tocc[key(t[1] + ox, t[2] + oy)] = true end

  -- unused input ports are not built; their tiles become ordinary ground
  local used_port = {}
  for _, pr in ipairs(cand.in_pairs) do used_port[pr[2].idx] = true end
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
  for _, pr in ipairs(cand.out_pairs) do tfed[key(pr[1].fx, pr[1].fy)] = pr end

  local area = world.area
  local occ, fed, wspans = world._occ, world._fed, world._spans

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
    -- ug_start: the template's output port may become an entrance
    jobs[#jobs + 1] = {sx = port.fx, sy = port.fy, sdir = var.flow,
                       tx = o.x, ty = o.y, tdir = o.dir, side_ok = o.side_ok,
                       ug_end = o.ent.kind == "belt",
                       ug_start = {port.fx - DX[var.flow], port.fy - DY[var.flow]},
                       port_start = port.idx}
  end
  -- reserve each job's start tile (it is forced: something pushes into it)
  local reserved = {}
  for i, j in ipairs(jobs) do reserved[key(j.sx, j.sy)] = i end
  local n = #jobs

  -- hard constraints for job ji
  local function make_passable(ji)
    local job = jobs[ji]
    return function(x, y)
      if not in_area(area, x, y) then return false end
      local kk = key(x, y)
      if tocc[kk] or not free(x, y) then return false end
      local isstart = (x == job.sx and y == job.sy)
      if isstart then return true end
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

  -- Negotiated congestion: route every job, letting them overlap at a
  -- price that rises each round, until no tile is shared. Undergrounds
  -- also claim their whole line (per axis) so two pairs never interleave.
  local usage, history, paths = {}, {}, {}
  local ax_use, ax_hist = {[0] = {}, {}}, {[0] = {}, {}}
  local present = 0.5
  local function tilecost(kk)
    local u = usage[kk] or 0
    return (1 + clear_at(kk) + (history[kk] or 0)) * (1 + present * u)
  end
  local ugctx
  if use_ug then
    ugctx = {
      max = world.ug_max or 5, end_ok = end_ok, pass_ok = pass_ok,
      cost = function(kk, axis)
        return (ax_hist[axis][kk] or 0) + present * (ax_use[axis][kk] or 0)
      end,
    }
  end
  local ctxs = {}
  for i = 1, n do
    ctxs[i] = {passable = make_passable(i), tilecost = tilecost, ug = ugctx}
  end

  -- every (map, key) a path claims
  local function claims(path)
    local list = {}
    for i, p in ipairs(path) do
      list[#list + 1] = {usage, key(p.x, p.y)}
      if p.kind == "ug" and p.io == "in" then
        local q = path[i + 1]
        local axis = p.dir % 2
        local len = math.abs(q.x - p.x) + math.abs(q.y - p.y)
        for k = 0, len do
          list[#list + 1] = {ax_use[axis], key(p.x + DX[p.dir] * k, p.y + DY[p.dir] * k)}
        end
      end
    end
    return list
  end

  local order = {}
  for i = 1, n do order[i] = i end
  table.sort(order, function(p, q)
    local jp, jq = jobs[p], jobs[q]
    return manhattan(jp.sx, jp.sy, jp.tx, jp.ty) < manhattan(jq.sx, jq.sy, jq.tx, jq.ty)
  end)
  local max_nodes = world.max_nodes or 12000
  local best_conf, stall = nil, 0
  for _ = 1, (world.route_iterations or 12) do
    for _, ji in ipairs(order) do
      local old = paths[ji]
      if old then
        for _, c in ipairs(claims(old)) do c[1][c[2]] = c[1][c[2]] - 1 end
      end
      local path = route(jobs[ji], ctxs[ji], max_nodes, world._work)
      if not path then return nil end   -- unroutable even with overlaps
      paths[ji] = path
      for _, c in ipairs(claims(path)) do c[1][c[2]] = (c[1][c[2]] or 0) + 1 end
    end
    local nconf = 0
    for _, pair in ipairs({{usage, history}, {ax_use[0], ax_hist[0]}, {ax_use[1], ax_hist[1]}}) do
      for kk, u in pairs(pair[1]) do
        if u > 1 then
          nconf = nconf + 1
          pair[2][kk] = (pair[2][kk] or 0) + 1
        end
      end
    end
    if nconf == 0 then
      -- template ports replaced by a route's underground are not built
      local dropped = {}
      for i = 1, n do
        local path, job = paths[i], jobs[i]
        local first, last = path[1], path[#path]
        if job.port_start and first and first.replace then
          dropped[job.port_start] = true
          first.replace = nil
        end
        if job.port_end and last and last.replace then
          dropped[job.port_end] = true
          last.replace = nil
        end
      end
      local ents, cost = {}, 0
      for i, e in ipairs(var.ents) do
        if not (e.port == "in" and not used_port[i]) and not dropped[i] then
          local r = {kind = e.kind, x = e.x + ox, y = e.y + oy, dir = e.dir, io = e.io}
          if e.x2 then r.x2, r.y2 = e.x2 + ox, e.y2 + oy end
          ents[#ents + 1] = r
        end
      end
      for i = 1, n do
        local path = paths[i]
        for pi, p in ipairs(path) do
          ents[#ents + 1] = {kind = p.kind, x = p.x, y = p.y, dir = p.dir, io = p.io,
                             replace = p.replace, route = i}
          cost = cost + 1 + clear_at(key(p.x, p.y))
          if p.kind == "ug" and p.io == "in" then cost = cost + UG_COST end
          if pi > 1 and path[pi - 1].dir ~= p.dir then cost = cost + TURN_COST end
        end
      end
      return ents, cost
    end
    -- give up on this candidate when overlaps stop shrinking
    if not best_conf or nconf < best_conf then best_conf, stall = nconf, 0
    else stall = stall + 1 end
    if stall >= 4 then return nil end
    present = present * 1.8
  end
  return nil
end

function planner.plan(world)
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

  -- candidate templates: hand-drawn ones, else a generated design
  local tpls = {}
  local want_lane = (n == 1 and m == 1)
  for _, t in ipairs(world.templates) do
    if t.outputs == m and t.inputs >= n and (t.lane or false) == want_lane then
      tpls[#tpls + 1] = t
    end
  end
  if #tpls == 0 and not want_lane then
    tpls[1] = generator.template(n, m, world.ug_max or 5)
  end
  if #tpls == 0 then return nil, {"lbb.no-template", n, m, generator.MAX} end

  -- world.blocked(x, y): true = can't build, false = free, a number = can
  -- build after clearing (trees, rocks, cliffs), at that extra cost
  local blocked_cache = {}
  local occ, fed, spans = world._occ, world._fed, world._spans
  local function free(x, y)
    local kk = key(x, y)
    if occ[kk] then return false end
    local b = blocked_cache[kk]
    if b == nil then
      b = world.blocked and world.blocked(x, y) or false
      blocked_cache[kk] = b
    end
    return b ~= true
  end
  local function clear_at(kk)
    local b = blocked_cache[kk]
    return type(b) == "number" and b or 0
  end

  -- majority input direction is the preferred flow direction
  local dir_votes = {[0] = 0, 0, 0, 0}
  for _, i in ipairs(inputs) do dir_votes[i.dir] = dir_votes[i.dir] + 1 end

  local input_start = {}
  for _, i in ipairs(inputs) do input_start[key(i.sx, i.sy)] = i end
  local output_tile = {}
  for _, o in ipairs(outputs) do output_tile[key(o.x, o.y)] = o end

  -- centroids of input starts / output belts, and of each variant's ports
  local icx, icy = centroid(inputs, "sx", "sy")
  local ocx, ocy = centroid(outputs, "x", "y")
  for _, tpl in ipairs(tpls) do
    for _, var in ipairs(variants_of(tpl)) do
      if not var.in_cx then
        local ip, op = {}, {}
        for _, idx in ipairs(var.inputs) do local e = var.ents[idx]; ip[#ip + 1] = {x = e.x, y = e.y} end
        for _, idx in ipairs(var.outputs) do
          local e = var.ents[idx]
          op[#op + 1] = {x = e.x + DX[e.dir], y = e.y + DY[e.dir]}
        end
        var.in_cx, var.in_cy = centroid(ip, "x", "y")
        var.out_cx, var.out_cy = centroid(op, "x", "y")
      end
    end
  end

  local cands = {}
  for ti, tpl in ipairs(tpls) do
    for _, var in ipairs(variants_of(tpl)) do
      if var.ug_len <= (world.ug_max or 5) then
        for ox = a.x1, a.x2 - var.w + 1 do
          for oy = a.y1, a.y2 - var.h + 1 do
            local ok = true
            for _, t in ipairs(var.tiles) do
              local x, y = t[1] + ox, t[2] + oy
              if not free(x, y) then ok = false; break end
              local kk = key(x, y)
              if fed[kk] then
                -- only an input end may push straight into a template tile
                local idx = var.occ[key(t[1], t[2])]
                local e = var.ents[idx]
                if not (e.port == "in" and input_start[kk] and #fed[kk] == 1) then ok = false; break end
              end
            end
            if ok then
              for _, t in ipairs(var.keep) do
                local x, y = t[1] + ox, t[2] + oy
                if not in_area(a, x, y) or not free(x, y) then ok = false; break end
              end
            end
            if ok then
              for _, s in ipairs(var.spans) do
                local sp = spans[key(s[1] + ox, s[2] + oy)]
                local here = occ[key(s[1] + ox, s[2] + oy)]
                if (sp and sp:find(tostring(s[3]), 1, true)) or
                   (here and here.kind == "ug" and here.dir % 2 == s[3]) then ok = false; break end
              end
            end
            if ok then
              -- template undergrounds must not sit on the line of an existing pair
              for _, s in ipairs(var.ugends) do
                local sp = spans[key(s[1] + ox, s[2] + oy)]
                if sp and sp:find(tostring(s[3]), 1, true) then ok = false; break end
              end
            end
            if ok then
              -- output port fronts must be buildable or be an output start
              local oports = {}
              for _, idx in ipairs(var.outputs) do
                local e = var.ents[idx]
                local fx, fy = e.x + ox + DX[e.dir], e.y + oy + DY[e.dir]
                local fk = key(fx, fy)
                if not (output_tile[fk] or (in_area(a, fx, fy) and free(fx, fy) and not fed[fk])) then
                  ok = false; break
                end
                oports[#oports + 1] = {fx = fx, fy = fy, idx = idx}
              end
              if ok then
                local iports = {}
                for _, idx in ipairs(var.inputs) do
                  local e = var.ents[idx]
                  iports[#iports + 1] = {x = e.x + ox, y = e.y + oy, idx = idx}
                end
                -- cheap estimate; exact pairing is done only for the best few
                local pcx, pcy = var.in_cx + ox, var.in_cy + oy
                local qcx, qcy = var.out_cx + ox, var.out_cy + oy
                local clear = 0
                for _, t in ipairs(var.tiles) do clear = clear + clear_at(key(t[1] + ox, t[2] + oy)) end
                local h_cost = n * manhattan(icx, icy, pcx, pcy) + m * manhattan(qcx, qcy, ocx, ocy)
                             + (#var.tiles) * 0.3 + (n - dir_votes[var.flow]) * 2 + clear
                cands[#cands + 1] = {var = var, ox = ox, oy = oy, tpl = tpl, clear = clear,
                                     iports = iports, oports = oports, h = h_cost}
              end
            end
          end
        end
      end
    end
  end
  if #cands == 0 then return nil, {"lbb.no-room", n, m} end
  table.sort(cands, function(p, q) return p.h < q.h end)

  local budget = world.budget or {}
  local max_c = budget.candidates or 40
  world._work = {n = budget.work or 300000}
  local max_s = budget.successes or 3

  -- exact pairing + estimate for the most promising placements, then re-rank
  local top = {}
  for i = 1, math.min(#cands, max_c * 3) do
    local c = cands[i]
    local ip, icost = assign_inputs(inputs, c.iports, c.var.flow)
    local op, ocost = assign_outputs(outputs, c.oports, c.var.flow)
    c.in_pairs, c.out_pairs = ip, op
    c.h = icost + ocost + (#c.var.tiles) * 0.3 + (n - dir_votes[c.var.flow]) * 2 + c.clear
    top[#top + 1] = c
  end
  table.sort(top, function(p, q) return p.h < q.h end)
  cands = top
  local best, best_cost, best_cand
  local successes = 0
  for i = 1, math.min(#cands, max_c) do
    local cand = cands[i]
    if best_cost and cand.h > best_cost + 8 then break end
    if world._work.n <= 0 then break end
    -- plain belts first; undergrounds only when belts can't make it
    local ents, cost = try_candidate(world, cand, free, clear_at, false)
    local plain = ents ~= nil
    if not ents and (world.ug_max or 5) >= 2 and not world.no_route_ug and world._work.n > 0 then
      ents, cost = try_candidate(world, cand, free, clear_at, true)
    end
    if ents then
      cost = cost + (#cand.var.tiles) * 0.3 + cand.clear
      if not best_cost or cost < best_cost then best, best_cost, best_cand = ents, cost, cand end
      -- a placement that needed undergrounds is a fallback: keep looking
      if plain then
        successes = successes + 1
        if successes >= max_s then break end
      end
    end
  end
  if not best then
    if world._work.n <= 0 then return nil, {"lbb.gave-up", n, m} end
    return nil, {"lbb.no-route", n, m}
  end
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
  return {template = best_cand.tpl, entities = best, n_in = n, n_out = m, cost = best_cost,
          flow = best_cand.var.flow, inputs = inputs, outputs = outputs, clear = clear}
end

return planner
