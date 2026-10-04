#!/usr/bin/env python3
"""End-to-end tests: run scripts/planner.lua (Lua 5.2 via lupa) on synthetic
worlds, then verify the complete planned layout with the flow simulator.

World maps use the template symbols plus '#' for an obstacle. The selection
area is given separately; belts outside it are still part of the world.

python3 tools/test_planner.py            fixed scenarios + random fuzz
python3 tools/test_planner.py --show     also print each planned layout
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import DIRS, SYM, UG, add, check_balancer  # noqa: E402
from lupa import lua52  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SHOW = '--show' in sys.argv
CH = {0: '^', 1: '>', 2: 'v', 3: '<'}
UGCH = {(0, 'in'): 'D', (0, 'out'): 'U', (1, 'in'): 'e', (1, 'out'): 'E',
        (3, 'in'): 'w', (3, 'out'): 'W', (2, 'in'): 'd', (2, 'out'): 'u'}

lua = lua52.LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = "{ROOT}/?.lua;" .. package.path')
planner = lua.eval('require("scripts.planner")')
templates = lua.eval('require("scripts.templates")')

make_world = lua.eval('''
function(ents, rocks, x1, y1, x2, y2, ug_max)
  local blocked = {}
  for _, r in ipairs(rocks) do blocked[r[1] .. "," .. r[2]] = true end
  return {
    area = {x1 = x1, y1 = y1, x2 = x2, y2 = y2},
    entities = ents,
    ug_spans = {},
    blocked = function(x, y) return blocked[x .. "," .. y] == true end,
    templates = require("scripts.templates"),
    ug_max = ug_max or 5,
  }
end''')


def call_plan(world):
    r = planner.plan(world)
    if isinstance(r, tuple):
        return r[0], r[1]
    return r, None


def lua_list(items):
    t = lua.table()
    for i, v in enumerate(items, 1):
        t[i] = v
    return t


def parse_world(rows):
    """-> (python ents {tile: simdict}, lua entity list, rocks)"""
    ents, lents, rocks = {}, [], []
    for y, row in enumerate(rows):
        for x, c in enumerate(row.split()):
            t = (x, y)
            if c in SYM:
                ents[t] = {'kind': 'belt', 'dir': SYM[c]}
                lents.append(lua.table(kind='belt', dir=SYM[c], speed=1,
                                       tiles=lua_list([lua_list([x, y])])))
            elif c == '#':
                rocks.append(lua_list([x, y]))
            elif c != '.':
                raise ValueError(c)
    return ents, lents, rocks


def run(name, rows, area, expect_ok=True, lane=None, ug_max=5):
    ents, lents, rocks = parse_world(rows)
    world = make_world(lua_list(lents), lua_list(rocks), *area, ug_max)
    plan, reason = call_plan(world)
    if plan is None:
        r = [reason[i] for i in range(1, len(reason) + 1)]
        if expect_ok:
            print(f'FAIL {name}: no plan {r}')
            return False
        print(f'PASS {name}: correctly refused {r[0]}')
        return True
    if not expect_ok:
        print(f'FAIL {name}: expected refusal, got {plan.template.name}')
        return False

    # merge planned entities into the world and verify
    full = dict(ents)
    errors = []
    pe = plan.entities
    sid = 1000
    for i in range(1, len(pe) + 1):
        e = pe[i]
        tiles = [(e.x, e.y)] + ([(e.x2, e.y2)] if e.kind == 'splitter' else [])
        for t in tiles:
            if t in full:
                errors.append(f'overlap at {t}')
            if not (area[0] <= t[0] <= area[2] and area[1] <= t[1] <= area[3]):
                errors.append(f'outside area at {t}')
        if e.kind == 'belt':
            full[tiles[0]] = {'kind': 'belt', 'dir': e.dir}
        elif e.kind == 'ug':
            full[tiles[0]] = {'kind': 'ug', 'dir': e.dir, 'io': e.io}
        else:
            sid += 1
            full[tiles[0]] = {'kind': 'splitter', 'dir': e.dir, 'half': 'L', 'id': sid}
            full[tiles[1]] = {'kind': 'splitter', 'dir': e.dir, 'half': 'R', 'id': sid}
    ins = [(plan.inputs[i].x, plan.inputs[i].y) for i in range(1, len(plan.inputs) + 1)]
    outs = [(plan.outputs[i].x, plan.outputs[i].y) for i in range(1, len(plan.outputs) + 1)]
    # remove belts downstream of outputs / upstream of inputs? not needed:
    # sinks absorb at the output start tile, sources inject at input ends.
    want_lane = lane if lane is not None else bool(plan.template.lane)
    ok, msgs = check_balancer(full, ins, outs, want_lane, '', quiet=True)
    ok = ok and not errors
    tag = 'PASS' if ok else 'FAIL'
    print(f'{tag} {name}: {plan.template.name} flow={plan.flow} {plan.n_in}->{plan.n_out} '
          f'cost={plan.cost:.1f} ents={len(pe)}')
    for m in (errors + msgs)[:6]:
        print('    ', m)
    if SHOW or not ok:
        draw(full, rows, area)
    return ok


def draw(full, rows, area):
    h = len(rows)
    w = max(len(r.split()) for r in rows)
    for y in range(h):
        line = []
        for x in range(w):
            e = full.get((x, y))
            c = '.'
            if e:
                if e['kind'] == 'belt':
                    c = CH[e['dir']]
                elif e['kind'] == 'ug':
                    c = UGCH[(e['dir'], e['io'])]
                else:
                    c = 'S' if e['half'] == 'L' else 's'
            elif rows[y].split()[x] == '#':
                c = '#'
            inside = area[0] <= x <= area[2] and area[1] <= y <= area[3]
            line.append(c if inside or c != '.' else ' ')
        print('      ' + ' '.join(line))


def blank(w, h):
    return [['.'] * w for _ in range(h)]


def rows_of(g):
    return [' '.join(r) for r in g]


def scenario_straight(n, m, gap=10, w=14, in_off=2, out_off=4, dirn=2):
    """n inputs flowing south from the top, m outputs leaving at the bottom."""
    h = gap + 4
    g = blank(w, h)
    for i in range(n):
        g[0][in_off + i] = 'v'
        g[1][in_off + i] = 'v'
    for j in range(m):
        g[h - 2][out_off + j] = 'v'
        g[h - 1][out_off + j] = 'v'
    return rows_of(g), (0, 1, w - 1, h - 2)


def scenario_turn(n, m):
    """inputs from the north, outputs leave to the east."""
    w, h = 16, 16
    g = blank(w, h)
    for i in range(n):
        g[0][2 + i] = 'v'
        g[1][2 + i] = 'v'
    for j in range(m):
        g[8 + j][w - 2] = '>'
        g[8 + j][w - 1] = '>'
    return rows_of(g), (0, 1, w - 2, h - 1)


def fixed():
    ok = True
    combos = [(1, 1), (1, 2), (2, 1), (2, 2), (3, 1), (4, 1), (3, 2), (4, 2),
              (1, 4), (2, 4), (3, 4), (4, 4), (1, 3), (2, 3), (3, 3)]
    for n, m in combos:
        rows, area = scenario_straight(n, m, gap=14 if m == 3 else 10)
        ok &= run(f'straight {n}->{m}', rows, area)
    for n, m in [(2, 2), (4, 4), (3, 3), (1, 1), (2, 4)]:
        rows, area = scenario_turn(n, m)
        ok &= run(f'turn {n}->{m}', rows, area)

    # obstacles in the middle of the gap
    rows, area = scenario_straight(4, 4, gap=14, w=16)
    g = [r.split() for r in rows]
    for x in range(0, 9):
        g[8][x] = '#'
    ok &= run('rocks 4->4', rows_of(g), area)

    # not enough room
    rows, area = scenario_straight(4, 4, gap=3, w=8)
    ok &= run('too small 4->4', rows, area, expect_ok=False)
    # unsupported count
    rows, area = scenario_straight(4, 3, gap=10)
    ok &= run('unsupported 4->3', rows, area, expect_ok=False)
    # weak underground tier cannot fit the 4x4 crossing (needs 2)
    rows, area = scenario_straight(4, 4)
    ok &= run('ug range 1', rows, area, expect_ok=False, ug_max=1)
    return ok


def fuzz(seed, count):
    rnd = random.Random(seed)
    ok = True
    made = 0
    for k in range(count):
        n = rnd.randint(1, 4)
        m = rnd.randint(1, 4)
        if (n, m) == (4, 3):
            continue
        w, h = rnd.randint(9, 20), rnd.randint(10, 20)
        g = blank(w, h)
        # inputs enter from the top edge flowing south
        xs = sorted(rnd.sample(range(0, w), n))
        for x in xs:
            g[0][x] = 'v'
        # outputs leave via bottom, left or right edge
        side = rnd.choice(['bottom', 'left', 'right'])
        if side == 'bottom':
            for x in sorted(rnd.sample(range(0, w), m)):
                g[h - 1][x] = 'v'
                g[h - 2][x] = 'v'
        else:
            ys = sorted(rnd.sample(range(h // 2, h), m))
            for y in ys:
                if side == 'left':
                    g[y][0] = '<'
                    g[y][1] = '<'
                else:
                    g[y][w - 1] = '>'
                    g[y][w - 2] = '>'
        # rocks
        for _ in range(rnd.randint(0, (w * h) // 18)):
            x, y = rnd.randrange(w), rnd.randrange(2, h - 2)
            if g[y][x] == '.':
                g[y][x] = '#'
        # the area is everything except the outermost belts, so every input
        # comes from outside and every output leaves
        ax1 = 1 if side == 'left' else 0
        ax2 = w - 2 if side == 'right' else w - 1
        ay2 = h - 2 if side == 'bottom' else h - 1
        # input/outputs: one tile inside the area too (dangling ends)
        for x in xs:
            g[1][x] = 'v'
        rows = rows_of(g)
        # skip worlds where an output tile was overwritten
        ents, lents, rocks = parse_world(rows)
        world = make_world(lua_list(lents), lua_list(rocks), ax1, 1, ax2, ay2, 5)
        plan, reason = call_plan(world)
        if plan is None:
            continue
        made += 1
        ok &= run(f'fuzz#{k} {n}->{m} {side} {w}x{h}', rows, (ax1, 1, ax2, ay2))
    print(f'fuzz: {made} planned layouts verified')
    return ok


if __name__ == '__main__':
    good = fixed()
    good &= fuzz(1234, 150)
    print('ALL PLANNER TESTS OK' if good else 'PLANNER TESTS FAILED')
    sys.exit(0 if good else 1)
