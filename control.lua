-- Belt Balancer Planner: runtime glue between Factorio and scripts/planner.lua

local planner = require("scripts.planner")
local templates = require("scripts.templates")

local TOOL = "lbb-balancer-tool"
local TAG = "lbb"

local D = defines.direction
local TO_DEF = {[0] = D.north, [1] = D.east, [2] = D.south, [3] = D.west}
local FROM_DEF = {}
for k, v in pairs(TO_DEF) do FROM_DEF[v] = k end

local KIND = {["transport-belt"] = "belt", ["underground-belt"] = "ug", ["splitter"] = "splitter"}

-- things in the way that are marked for deconstruction, with the planner's
-- extra cost of building there
local CLEAR_COST = {["tree"] = 1, ["simple-entity"] = 2, ["cliff"] = 6}
local CLEAR_TYPES = {"tree", "simple-entity", "cliff"}

local function init_storage()
  storage.builds = storage.builds or {}
end
script.on_init(init_storage)
script.on_configuration_changed(init_storage)

------------------------------------------------------------------ helpers

local function tell(player, msg, ok)
  player.create_local_flying_text{text = msg, create_at_cursor = true}
  if not ok then player.play_sound{path = "utility/cannot_build"} end
  if player.mod_settings["lbb-verbose"].value then player.print(msg) end
end

local function tile_of(pos) return {math.floor(pos.x), math.floor(pos.y)} end

local function tile_box(x, y) return {{x + 0.02, y + 0.02}, {x + 0.98, y + 0.98}} end

-- Can this force blow up the cliff (cliff explosives available)?
local function cliff_removable(force, cliff)
  local ok, res = pcall(function()
    local item = cliff.prototype.cliff_explosive_prototype
    if not item then return false end
    local recipe = force.recipes[item]
    return recipe == nil or recipe.enabled
  end)
  return ok and res or false
end

-- Real entity or ghost -> (type, name, prototype)
local function identity(e)
  if e.type == "entity-ghost" then return e.ghost_type, e.ghost_name, e.ghost_prototype end
  return e.type, e.name, e.prototype
end

local function underground_io(e)
  local ok, v = pcall(function() return e.belt_to_ground_type end)
  if ok and v then return v == "input" and "in" or "out" end
  return "in"
end

local function underground_partner(e)
  if e.type == "entity-ghost" then return nil end
  local ok, n = pcall(function() return e.neighbours end)
  if ok and n and n.valid then return n end
  return nil
end

-- Convert one LuaEntity into the planner's world format.
local function convert(e, spans)
  local etype, name, proto = identity(e)
  local kind = KIND[etype]
  if kind == "belt" or kind == "ug" then
    local r = {kind = kind, tiles = {tile_of(e.position)}, dir = FROM_DEF[e.direction] or 0,
               name = name, speed = proto.belt_speed, entity = e}
    if kind == "ug" then
      r.io = underground_io(e)
      local p = underground_partner(e)
      if p then
        local pt = tile_of(p.position)
        r.partner = pt
        if r.io == "in" then
          local t = r.tiles[1]
          local dx, dy = pt[1] - t[1], pt[2] - t[2]
          local n = math.max(math.abs(dx), math.abs(dy))
          for i = 1, n - 1 do
            spans[#spans + 1] = {x = t[1] + dx / n * i, y = t[2] + dy / n * i, axis = r.dir % 2}
          end
        end
      end
    end
    return r
  elseif kind == "splitter" then
    local p, d = e.position, FROM_DEF[e.direction] or 0
    local tiles
    if d % 2 == 0 then
      tiles = {{math.floor(p.x - 0.5), math.floor(p.y)}, {math.floor(p.x + 0.5), math.floor(p.y)}}
    else
      tiles = {{math.floor(p.x), math.floor(p.y - 0.5)}, {math.floor(p.x), math.floor(p.y + 0.5)}}
    end
    return {kind = "splitter", tiles = tiles, dir = d, name = name, speed = proto.belt_speed, entity = e}
  elseif e.type == "entity-ghost" then
    -- ghosts of anything else: the game's placement check ignores them,
    -- so record their footprint ourselves
    local b = e.bounding_box
    local tiles = {}
    for x = math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1 do
      for y = math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1 do
        tiles[#tiles + 1] = {x, y}
      end
    end
    return {kind = "other", tiles = tiles}
  end
  return nil
end

-- Find a buildable prototype of `ptype` with the given belt speed, preferring
-- the one named like the belt ("fast-transport-belt" -> "fast-splitter").
local function prototype_for(ptype, speed, belt_name)
  if belt_name then
    local prefix = belt_name:gsub("transport%-belt$", "")
    local guess = ({["splitter"] = "splitter", ["underground-belt"] = "underground-belt",
                    ["transport-belt"] = "transport-belt"})[ptype]
    local p = prototypes.entity[prefix .. guess]
    if p and p.type == ptype and math.abs(p.belt_speed - speed) < 1e-9 then return p end
  end
  local best
  for name, p in pairs(prototypes.get_entity_filtered{{filter = "type", type = ptype}}) do
    if not p.hidden and p.items_to_place_this and #p.items_to_place_this > 0
       and math.abs(p.belt_speed - speed) < 1e-9 then
      if not best or name < best.name then best = p end
    end
  end
  return best
end

-- Choose belt / splitter / underground names from the detected belts.
local function choose_tier(player, ends)
  local mode = player.mod_settings["lbb-tier"].value
  local pick
  for _, e in ipairs(ends) do
    if e.speed and (not pick or (mode == "fastest" and e.speed > pick.speed)
                    or (mode == "slowest" and e.speed < pick.speed)) then
      pick = e
    end
  end
  if not pick then return nil end
  local belt_name = (pick.kind == "belt") and pick.name or nil
  local belt = belt_name and prototypes.entity[belt_name] or prototype_for("transport-belt", pick.speed)
  if not belt then return nil end
  local splitter = prototype_for("splitter", pick.speed, belt.name)
  local ug = prototype_for("underground-belt", pick.speed, belt.name)
  if not (splitter and ug) then return nil end
  return {belt = belt.name, splitter = splitter.name, ug = ug.name,
          ug_max = ug.max_underground_distance or 5}
end

-------------------------------------------------------------------- build

local function area_to_tiles(area)
  local lt, rb = area.left_top, area.right_bottom
  local x1, y1 = math.floor(lt.x), math.floor(lt.y)
  local x2, y2 = math.ceil(rb.x) - 1, math.ceil(rb.y) - 1
  if x2 < x1 then x2 = x1 end
  if y2 < y1 then y2 = y1 end
  return {x1 = x1, y1 = y1, x2 = x2, y2 = y2}
end

local function remove_ghosts(list)
  local n = 0
  for _, g in ipairs(list or {}) do
    if g.valid and g.type == "entity-ghost" then g.destroy(); n = n + 1 end
  end
  return n
end

-- build = {ghosts = {...}, marked = {...}, removed = {...}}
-- (older saves: a plain ghost list)
local function ghosts_of(build)
  if not build then return {} end
  return build.ghosts or build
end

-- Undo what a build did besides placing ghosts: deconstruction marks, and
-- belt ghosts it replaced by underground ghosts.
local function cancel_marks(build, force, player)
  for _, e in ipairs((build and build.marked) or {}) do
    if e.valid and e.to_be_deconstructed() then e.cancel_deconstruction(force) end
  end
  for _, g in ipairs((build and build.removed) or {}) do
    if g.surface.valid then
      g.surface.create_entity{name = "entity-ghost", inner_name = g.name, position = g.position,
                              direction = g.direction, force = force, player = player}
    end
  end
end

-- World test for the planner: false = free, true = can't build, a number =
-- can build once trees / rocks / cliffs are removed (that is the extra cost).
local function make_blocked(surface, force, belt)
  return function(x, y)
    local params = {name = belt, position = {x + 0.5, y + 0.5}, direction = D.north, force = force,
                    build_check_type = defines.build_check_type.manual_ghost}
    if surface.can_place_entity(params) then return false end
    -- would it fit if everything that can be deconstructed were gone?
    params.forced = true
    if not surface.can_place_entity(params) then return true end
    local cost = 0
    for _, e in ipairs(surface.find_entities_filtered{area = tile_box(x, y)}) do
      local c = CLEAR_COST[e.type]
      if c then
        if e.type == "cliff" and not cliff_removable(force, e) then return true end
        if c > cost then cost = c end
      elseif e.force == force and e.type ~= "entity-ghost" and e.type ~= "character" then
        return true -- never tear down the player's own buildings
      end
    end
    return cost > 0 and cost or true
  end
end

local function on_select(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local surface, force = event.surface, player.force
  local tiles = area_to_tiles(event.area)

  -- gather everything around the selection (1 tile margin for chain tracing)
  local search = {{tiles.x1 - 1, tiles.y1 - 1}, {tiles.x2 + 2, tiles.y2 + 2}}
  local entities, spans = {}, {}
  for _, e in ipairs(surface.find_entities_filtered{area = search, force = force}) do
    local r = convert(e, spans)
    if r then entities[#entities + 1] = r end
  end

  local world = {
    area = tiles,
    entities = entities,
    ug_spans = spans,
    templates = templates,
  }

  -- detect first, to pick the belt tier for collision checks and naming
  local ins, outs = planner.detect(world)
  local ends = {}
  for _, i in ipairs(ins) do ends[#ends + 1] = i.ent end
  for _, o in ipairs(outs) do ends[#ends + 1] = o.ent end
  local tier = choose_tier(player, ends)
  if not tier then
    if #ins == 0 or #outs == 0 then
      tell(player, {"lbb.no-ends", #ins, #outs}, false)
    else
      tell(player, {"lbb.no-tier"}, false)
    end
    return
  end
  world.ug_max = tier.ug_max
  world._occ = nil -- planner.plan re-indexes
  world.blocked = make_blocked(surface, force, tier.belt)

  local plan, reason = planner.plan(world)
  if not plan then
    tell(player, reason, false)
    return
  end

  -- input ends / output starts the routes turn into undergrounds
  local belt_at = {}
  for _, r in ipairs(entities) do
    if r.kind == "belt" then belt_at[r.tiles[1][1] .. "," .. r.tiles[1][2]] = r.entity end
  end
  local created, marked, removed = {}, {}, {}
  local function rollback()
    remove_ghosts(created)
    cancel_marks({marked = marked, removed = removed}, force, player)
  end
  for _, e in ipairs(plan.entities) do
    if e.replace then
      local old = belt_at[e.x .. "," .. e.y]
      if old and old.valid then
        if old.type == "entity-ghost" then
          removed[#removed + 1] = {surface = surface, name = old.ghost_name, position = old.position,
                                   direction = old.direction}
          old.destroy()
        elseif old.order_deconstruction(force, player) then
          marked[#marked + 1] = old
        end
      end
    end
  end
  -- trees, rocks and cliffs under the new entities
  for _, t in ipairs(plan.clear or {}) do
    for _, c in ipairs(surface.find_entities_filtered{area = tile_box(t.x, t.y), type = CLEAR_TYPES}) do
      if c.valid and not c.to_be_deconstructed() and c.order_deconstruction(force, player) then
        marked[#marked + 1] = c
      end
    end
  end

  -- place ghosts; roll back if anything fails
  for _, e in ipairs(plan.entities) do
    local params = {name = "entity-ghost", force = force, player = player,
                    direction = TO_DEF[e.dir], raise_built = true}
    if e.kind == "splitter" then
      params.inner_name = tier.splitter
      params.position = {(e.x + e.x2) / 2 + 0.5, (e.y + e.y2) / 2 + 0.5}
    elseif e.kind == "ug" then
      params.inner_name = tier.ug
      params.position = {e.x + 0.5, e.y + 0.5}
      params.type = (e.io == "in") and "input" or "output"
    else
      params.inner_name = tier.belt
      params.position = {e.x + 0.5, e.y + 0.5}
    end
    local ghost = surface.create_entity(params)
    if not (ghost and ghost.valid) then
      rollback()
      tell(player, {"lbb.place-failed", e.x, e.y}, false)
      return
    end
    pcall(function() ghost.tags = {[TAG] = true} end)
    created[#created + 1] = ghost
  end

  storage.builds[player.index] = {ghosts = created, marked = marked, removed = removed}
  local tname = {"lbb-template." .. plan.template.name}
  if #marked > 0 then
    tell(player, {"lbb.placed-clear", tname, plan.n_in, plan.n_out, #created, #marked}, true)
  else
    tell(player, {"lbb.placed", tname, plan.n_in, plan.n_out, #created}, true)
  end
end

local function on_alt_select(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local list = {}
  for _, e in ipairs(event.entities) do
    if e.valid and e.type == "entity-ghost" and e.tags and e.tags[TAG] then list[#list + 1] = e end
  end
  local n = remove_ghosts(list)
  -- once every ghost of the last build is gone, also drop its deconstruction marks
  local build = storage.builds[player.index]
  if build then
    local left = false
    for _, g in ipairs(ghosts_of(build)) do if g.valid then left = true; break end end
    if not left then
      cancel_marks(build, player.force, player)
      storage.builds[player.index] = nil
    end
  end
  tell(player, {"lbb.removed", n}, true)
end

script.on_event(defines.events.on_player_selected_area, function(event)
  if event.item == TOOL then on_select(event) end
end)

script.on_event(defines.events.on_player_alt_selected_area, function(event)
  if event.item == TOOL then on_alt_select(event) end
end)

script.on_event("lbb-remove-last", function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local build = storage.builds[player.index]
  local n = remove_ghosts(ghosts_of(build))
  cancel_marks(build, player.force, player)
  storage.builds[player.index] = nil
  tell(player, {"lbb.removed", n}, true)
end)
