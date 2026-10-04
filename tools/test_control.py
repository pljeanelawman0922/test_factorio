#!/usr/bin/env python3
"""Runs the real control.lua / data.lua / settings.lua against a small mock of
the Factorio 2.x API, fires a selection event and verifies the created ghosts
with the flow simulator."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import SYM, check_balancer  # noqa: E402
from lupa import lua52  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

MOCK = r'''
defines = {
  direction = {north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14},
  events = {on_player_selected_area = 101, on_player_alt_selected_area = 102},
  build_check_type = {script = 0, manual = 1, manual_ghost = 2, script_ghost = 3, blueprint_ghost = 4, ghost_revive = 5},
}
local function proto(name, type, speed, extra)
  local p = {name = name, type = type, belt_speed = speed, hidden = false,
             items_to_place_this = {{name = name, count = 1}}}
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end
local Y, R = 0.03125, 0.0625
prototypes = {entity = {
  ["transport-belt"] = proto("transport-belt", "transport-belt", Y),
  ["splitter"] = proto("splitter", "splitter", Y),
  ["underground-belt"] = proto("underground-belt", "underground-belt", Y, {max_underground_distance = 5}),
  ["fast-transport-belt"] = proto("fast-transport-belt", "transport-belt", R),
  ["fast-splitter"] = proto("fast-splitter", "splitter", R),
  ["fast-underground-belt"] = proto("fast-underground-belt", "underground-belt", R, {max_underground_distance = 7}),
}}
function prototypes.get_entity_filtered(filters)
  local out = {}
  for n, p in pairs(prototypes.entity) do if p.type == filters[1].type then out[n] = p end end
  return out
end

HANDLERS = {}
script = {
  on_init = function(f) HANDLERS.init = f end,
  on_configuration_changed = function(f) HANDLERS.config = f end,
  on_event = function(id, f) HANDLERS[id] = f end,
}
storage = {}
MESSAGES = {}
FORCE = {name = "player", recipes = {["cliff-explosives"] = {enabled = false}}}
PLAYER = {
  index = 1, force = FORCE,
  mod_settings = {["lbb-tier"] = {value = "fastest"}, ["lbb-verbose"] = {value = true}},
  print = function(m) MESSAGES[#MESSAGES + 1] = m end,
  create_local_flying_text = function(t) end,
  play_sound = function(t) end,
}
game = {get_player = function(i) return PLAYER end}

-- world
ENTITIES = {}
ROCKS = {}
local function in_box(p, a)
  return p.x >= a[1][1] and p.x <= a[2][1] and p.y >= a[1][2] and p.y <= a[2][2]
end
local function tilekey(x, y) return math.floor(x) .. "," .. math.floor(y) end
function occupied_tiles()
  local occ = {}
  for _, e in ipairs(ENTITIES) do
    if e.valid then
      local t = e.type == "entity-ghost" and e.ghost_type or e.type
      if t == "splitter" then
        local d = e.direction
        if d == 0 or d == 8 then
          occ[tilekey(e.position.x - 0.5, e.position.y)] = e
          occ[tilekey(e.position.x + 0.5, e.position.y)] = e
        else
          occ[tilekey(e.position.x, e.position.y - 0.5)] = e
          occ[tilekey(e.position.x, e.position.y + 0.5)] = e
        end
      else
        occ[tilekey(e.position.x, e.position.y)] = e
      end
    end
  end
  return occ
end
SURFACE = {}
function SURFACE.find_entities_filtered(f)
  local types
  if f.type then
    types = {}
    for _, t in ipairs(type(f.type) == "table" and f.type or {f.type}) do types[t] = true end
  end
  local out = {}
  for _, e in ipairs(ENTITIES) do
    if e.valid and in_box(e.position, f.area) and (not types or types[e.type]) then out[#out + 1] = e end
  end
  return out
end
local DECON = {tree = true, cliff = true}
function SURFACE.can_place_entity(p)
  local k = tilekey(p.position[1], p.position[2])
  if ROCKS[k] then return false end
  local occ = occupied_tiles()
  local o = occ[k]
  if o and o.type ~= "entity-ghost" and not (p.forced and DECON[o.type]) then return false end
  return true
end
-- deconstruction orders on any mock entity
local function decon(e, ok)
  e.marked = false
  e.order_deconstruction = function(force, player)
    if not ok() then return false end
    e.marked = true
    return true
  end
  e.cancel_deconstruction = function(force) e.marked = false end
  e.to_be_deconstructed = function() return e.marked end
  return e
end
function add_tree(x, y)
  ENTITIES[#ENTITIES + 1] = decon({valid = true, type = "tree", name = "tree-01", force = "neutral",
    position = {x = x + 0.5, y = y + 0.5}, prototype = {}}, function() return true end)
end
function add_cliff(x, y)
  ENTITIES[#ENTITIES + 1] = decon({valid = true, type = "cliff", name = "cliff", force = "neutral",
    position = {x = x + 0.5, y = y + 0.5}, prototype = {cliff_explosive_prototype = "cliff-explosives"}},
    function() return FORCE.recipes["cliff-explosives"].enabled end)
end
function SURFACE.create_entity(p)
  assert(p.name == "entity-ghost", "only ghosts expected")
  assert(prototypes.entity[p.inner_name], "unknown inner " .. tostring(p.inner_name))
  local e = {valid = true, type = "entity-ghost", ghost_name = p.inner_name,
             ghost_type = prototypes.entity[p.inner_name].type,
             ghost_prototype = prototypes.entity[p.inner_name],
             position = {x = p.position[1], y = p.position[2]}, direction = p.direction,
             belt_to_ground_type = p.type, created = true}
  e.destroy = function() e.valid = false end
  ENTITIES[#ENTITIES + 1] = e
  return e
end
function add_belt(name, x, y, dir)
  local e = {valid = true, type = prototypes.entity[name].type, name = name, prototype = prototypes.entity[name],
             position = {x = x + 0.5, y = y + 0.5}, direction = dir, force = FORCE}
  ENTITIES[#ENTITIES + 1] = decon(e, function() return true end)
end
'''

lua = lua52.LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = "{ROOT}/?.lua;" .. package.path')
lua.execute(MOCK)

# data stage & settings stage just need to load and declare things
data_items = []
lua.execute('data = {extend = function(self, t) for _, p in ipairs(t) do DATA_ITEMS[#DATA_ITEMS+1] = p end end}')
lua.execute('DATA_ITEMS = {}')
lua.execute(f'dofile("{ROOT}/settings.lua")')
lua.execute(f'dofile("{ROOT}/data.lua")')
names = lua.eval('(function() local s={} for _,p in ipairs(DATA_ITEMS) do s[#s+1]=p.type..":"..p.name end return table.concat(s," ") end)()')
print('data/settings declare:', names)
lua.execute(f'dofile("{ROOT}/control.lua")')
lua.eval('HANDLERS.init')()

DEF = {0: 0, 1: 4, 2: 8, 3: 12}
UNDEF = {v: k for k, v in DEF.items()}


def scenario(rows, area, belt='transport-belt', explosives=False):
    lua.execute('ENTITIES = {}; ROCKS = {}; MESSAGES = {}')
    lua.execute(f'FORCE.recipes["cliff-explosives"].enabled = {"true" if explosives else "false"}')
    ents = {}
    for y, row in enumerate(rows):
        for x, c in enumerate(row.split()):
            if c in SYM:
                lua.eval('add_belt')(belt, x, y, DEF[SYM[c]])
                ents[(x, y)] = {'kind': 'belt', 'dir': SYM[c]}
            elif c == '#':
                lua.execute(f'ROCKS["{x},{y}"] = true')
            elif c == 'T':
                lua.eval('add_tree')(x, y)
            elif c == 'C':
                lua.eval('add_cliff')(x, y)
    ev = lua.eval(f'''{{player_index = 1, item = "lbb-balancer-tool", surface = SURFACE,
        area = {{left_top = {{x = {area[0]}, y = {area[1]}}}, right_bottom = {{x = {area[2] + 1}, y = {area[3] + 1}}}}},
        entities = {{}}}}''')
    lua.eval('HANDLERS[defines.events.on_player_selected_area]')(ev)
    def ls(m):
        try:
            vals = list(m.values())
        except AttributeError:
            return str(m)
        return vals[0] if len(vals) == 1 else f"{vals[0]}({', '.join(ls(v) for v in vals[1:])})"
    msgs = [ls(m) for m in lua.eval('MESSAGES').values()]
    created = [e for e in lua.eval('ENTITIES').values() if e.created and e.valid]
    full = dict(ents)
    # belts marked for deconstruction are being replaced
    for e in lua.eval('ENTITIES').values():
        if e.marked and e.type == 'transport-belt':
            full.pop((int(e.position.x), int(e.position.y)), None)
    sid = 0
    for e in created:
        d = UNDEF[e.direction]
        px, py = e.position.x, e.position.y
        if e.ghost_type == 'splitter':
            sid += 1
            if d % 2 == 0:
                a, b = (int(round(px - 1)), int(py)), (int(round(px)), int(py))
            else:
                a, b = (int(px), int(round(py - 1))), (int(px), int(round(py)))
            # left half relative to facing direction
            left_of = {0: a, 2: b, 1: a, 3: b}[d]
            for t in (a, b):
                assert t not in full, f'overlap {t}'
                full[t] = {'kind': 'splitter', 'dir': d, 'half': 'L' if t == left_of else 'R', 'id': sid}
        elif e.ghost_type == 'underground-belt':
            t = (int(px), int(py))
            assert t not in full, f'overlap {t}'
            full[t] = {'kind': 'ug', 'dir': d, 'io': 'in' if e.belt_to_ground_type == 'input' else 'out'}
        else:
            t = (int(px), int(py))
            assert t not in full, f'overlap {t}'
            full[t] = {'kind': 'belt', 'dir': d}
    return msgs, created, full


ok_all = True


def check(name, rows, area, ins, outs, lane=False, belt='transport-belt', expect=None,
          explosives=False, post=None):
    """post: optional function(created ghosts) -> error string or None"""
    global ok_all
    msgs, created, full = scenario(rows, area, belt, explosives)
    names = sorted({e.ghost_name for e in created})
    if expect == 'fail':
        good = not created
        print(('PASS ' if good else 'FAIL ') + f'{name}: {msgs}')
        ok_all &= good
        return
    good, problems = check_balancer(full, ins, outs, lane, '', quiet=True)
    good = good and bool(created)
    if expect:
        good = good and names == sorted(expect)
    if post and good:
        err = post(created)
        if err:
            problems = [err] + list(problems)
            good = False
    print(('PASS ' if good else 'FAIL ') + f'{name}: {len(created)} ghosts {names} | {msgs[-1] if msgs else ""}')
    for p in problems[:4]:
        print('    ', p)
    ok_all &= good


def grid(w, h):
    return [['.'] * w for _ in range(h)]


# 4 -> 4 heading south, yellow belts
g = grid(12, 16)
for x in range(2, 6):
    g[0][x] = g[1][x] = 'v'
for x in range(4, 8):
    g[14][x] = g[15][x] = 'v'
rows = [' '.join(r) for r in g]
check('4->4 south (yellow)', rows, (0, 1, 11, 14), [(x, 1) for x in range(2, 6)], [(x, 14) for x in range(4, 8)],
      expect=['splitter', 'transport-belt', 'underground-belt'])
check('4->4 south (red tier names)', rows, (0, 1, 11, 14), [(x, 1) for x in range(2, 6)],
      [(x, 14) for x in range(4, 8)], belt='fast-transport-belt',
      expect=['fast-splitter', 'fast-transport-belt', 'fast-underground-belt'])

# 2 -> 3 heading east
g = grid(18, 10)
for y in (2, 3):
    g[y][0] = g[y][1] = '>'
for y in (4, 5, 6):
    g[y][16] = g[y][17] = '>'
rows = [' '.join(r) for r in g]
check('2->3 east', rows, (1, 0, 16, 9), [(1, 2), (1, 3)], [(16, 4), (16, 5), (16, 6)])

# 1 -> 1 lane balancer heading north
g = grid(8, 12)
g[11][3] = g[10][3] = '^'
g[1][4] = g[0][4] = '^'
rows = [' '.join(r) for r in g]
check('1->1 lanes north', rows, (0, 1, 7, 10), [(3, 10)], [(4, 1)], lane=True)

# 3 -> 2 heading west with rocks
g = grid(16, 10)
for y in (1, 2, 3):
    g[y][15] = g[y][14] = '<'
for y in (6, 7):
    g[y][0] = g[y][1] = '<'
for y in range(0, 6):
    g[y][7] = '#'
rows = [' '.join(r) for r in g]
check('3->2 west + rocks', rows, (1, 0, 14, 9), [(14, 1), (14, 2), (14, 3)], [(1, 6), (1, 7)])

# nothing selected that qualifies
g = grid(6, 6)
rows = [' '.join(r) for r in g]
check('empty selection', rows, (0, 0, 5, 5), [], [], expect='fail')

def marks_match(kinds):
    """every entity of these types under a ghost is marked, no other is"""
    def f(created):
        under = set()
        for e in created:
            under.add((int(e.position.x), int(e.position.y)))
            if e.ghost_type == 'splitter':  # mock splitters in these tests face north/south
                under.add((int(e.position.x - 1), int(e.position.y)))
        n = 0
        for e in lua.eval('ENTITIES').values():
            if e.type in kinds:
                t = (int(e.position.x), int(e.position.y))
                if bool(e.marked) != (t in under):
                    return f'{e.type} at {t}: marked={bool(e.marked)} under ghost={t in under}'
                n += bool(e.marked)
        return None if n else f'nothing of {kinds} was marked'
    return f


def south_rows(n, m, gap, w, band=None, sym='T'):
    g = grid(w, gap + 4)
    for x in range(2, 2 + n):
        g[0][x] = g[1][x] = 'v'
    for x in range(3, 3 + m):
        g[gap + 2][x] = g[gap + 3][x] = 'v'
    for y in band or []:
        for x in range(w):
            g[y][x] = sym
    return [' '.join(r) for r in g], (0, 1, w - 1, gap + 2), \
        [(x, 1) for x in range(2, 2 + n)], [(x, gap + 2) for x in range(3, 3 + m)]


# a band of trees across the whole gap: built through, trees marked
rows, area, ins, outs = south_rows(2, 2, 12, 10, band=[6, 7, 8])
check('2->2 through trees', rows, area, ins, outs, post=marks_match({'tree'}))

# cliffs: without cliff explosives the belts go under them, with them the
# cliffs are marked
def tunnels_no_marks(created):
    if any(e.marked for e in lua.eval('ENTITIES').values()):
        return 'something was marked'
    ugs = [e for e in created if e.ghost_type == 'underground-belt']
    above = {int(e.position.x) for e in ugs if e.position.y < 6}
    below = {int(e.position.x) for e in ugs if e.position.y > 8}
    if not above & below:
        return 'no underground pair under the cliffs'
    return None


rows, area, ins, outs = south_rows(2, 2, 12, 10, band=[6, 7], sym='C')
check('2->2 cliffs, no explosives', rows, area, ins, outs, post=tunnels_no_marks)
check('2->2 cliffs + explosives', rows, area, ins, outs, explosives=True, post=marks_match({'cliff'}))

# rock wall right after the input ends: inputs replaced by undergrounds
rows, area, ins, outs = south_rows(2, 2, 12, 10, band=[2], sym='#')
check('2->2 rock wall at inputs', rows, area, ins, outs, post=marks_match({'transport-belt'}))

# a count without hand-drawn template
rows, area, ins, outs = south_rows(6, 6, 24, 18)
check('6->6 generated', rows, area, ins, outs)

# bug report screenshot (+1 row): single belts lying inside the selection
rows = ['. . . . . . . . . .',
        '. . . . . . . . . .',
        '. . . . . . . > . .',
        '. . . . . . . > . .',
        '. . > . . . . > . .',
        '. . . . . . . . . .']
check('1->3 belts inside the selection', rows, (0, 0, 9, 5), [(2, 4)], [(7, 2), (7, 3), (7, 4)])
# third screenshot: the belts themselves are the balancer's ports
rows = ['. . . . . . .', '. . . . . . .', '. . . . . . >', '. . . . . . >', '. > . . . . >', '. . . . . . .']
check('1->3 tight (screenshot 3)', rows, (0, 0, 6, 5), [(1, 4)], [(6, 2), (6, 3), (6, 4)],
      post=lambda c: None if len(c) == 13 else f'{len(c)} ghosts, expected 13 (3 splitters + 10 belts)')

# too small: refused, with the design size and a selection size that works
rows = ['. . . . . >', '. . . . . >', '. . . . . >', '> . . . . .']
msgs, created, full = scenario(rows, (0, 0, 5, 3))
good = not created and 'lbb.try-size(8, 6, 1)' in msgs[-1] and 'lbb.no-route(1, 3)' in msgs[-1]
print(('PASS ' if good else 'FAIL ') + f'size hint: {msgs[-1]}')
ok_all &= good

# remove-last also takes back the deconstruction marks
rows, area, ins, outs = south_rows(2, 2, 12, 10, band=[6, 7, 8])
msgs, created, full = scenario(rows, area)
lua.eval('HANDLERS["lbb-remove-last"]')(lua.table(player_index=1))
still = [e for e in lua.eval('ENTITIES').values() if e.marked]
good = bool(created) and not still
print(('PASS ' if good else 'FAIL ') + f'remove-last cancels marks ({len(still)} still marked)')
ok_all &= good

# alt-select removes only our ghosts
g = grid(12, 16)
for x in range(2, 6):
    g[0][x] = g[1][x] = 'v'
for x in range(4, 8):
    g[14][x] = g[15][x] = 'v'
rows = [' '.join(r) for r in g]
msgs, created, full = scenario(rows, (0, 1, 11, 14))
# set tags the way control.lua does (mock ghosts accept the assignment)
tagged = [e for e in created if e.tags and e.tags['lbb']]
ev = lua.table(player_index=1, item='lbb-balancer-tool', entities=lua.table(*created))
lua.eval('HANDLERS[defines.events.on_player_alt_selected_area]')(ev)
left = [e for e in lua.eval('ENTITIES').values() if e.created and e.valid]
good = len(tagged) == len(created) and not left
print(('PASS ' if good else 'FAIL ') + f'alt-select removed {len(created) - len(left)}/{len(created)} tagged ghosts')
ok_all &= good

# remove-last hotkey
msgs, created, full = scenario(rows, (0, 1, 11, 14))
lua.eval('HANDLERS["lbb-remove-last"]')(lua.table(player_index=1))
left = [e for e in lua.eval('ENTITIES').values() if e.created and e.valid]
good = bool(created) and not left
print(('PASS ' if good else 'FAIL ') + f'remove-last removed {len(created) - len(left)}/{len(created)}')
ok_all &= good

print('ALL CONTROL TESTS OK' if ok_all else 'CONTROL TESTS FAILED')
sys.exit(0 if ok_all else 1)
