#!/usr/bin/env python3
"""Lane-level steady-state flow model of Factorio belts, used to verify the
balancer templates (and, from test_planner.py, complete planned layouts).

Model (unsaturated steady state, every output accepting):
  * straight belt / curve: lanes preserved
  * side-load onto a straight belt: everything goes to the near lane
  * a belt with exactly one side input and nothing behind is a curve
  * splitter: per lane, the combined input of both halves is split equally
    between the outputs that can reach a sink (an output in front of an
    empty tile is blocked)
  * underground belt: lanes preserved, entrance pairs with the first exit
    in the same direction within max distance

Usage: python3 tools/sim.py         -> verifies every template
"""
import os
import sys

DIRS = [(0, -1), (1, 0), (0, 1), (-1, 0)]  # N E S W, y grows south
SYM = {'^': 0, '>': 1, 'v': 2, '<': 3}
UG = {'D': (0, 'in'), 'U': (0, 'out'), 'e': (1, 'in'), 'E': (1, 'out'),
      'w': (3, 'in'), 'W': (3, 'out')}
UG_MAX = 5
L, R = 0, 1


def add(t, d, k=1):
    return (t[0] + DIRS[d][0] * k, t[1] + DIRS[d][1] * k)


def left(d):
    return (d + 3) % 4


def right(d):
    return (d + 1) % 4


def opp(d):
    return (d + 2) % 4


class SimError(Exception):
    pass


# ---------------------------------------------------------------- entities
# Each tile maps to a dict:
#   {'kind': 'belt', 'dir': d}
#   {'kind': 'ug', 'dir': d, 'io': 'in'|'out'}
#   {'kind': 'splitter', 'dir': d, 'half': 'L'|'R', 'id': n}
# Optional flags: 'sink': True  (absorbs everything entering it)

def parse_grid(grid):
    rows = [r.split() for r in grid]
    h = len(rows)
    w = max(len(r) for r in rows)
    ents = {}
    sid = 0
    for y, row in enumerate(rows):
        x = 0
        while x < len(row):
            c = row[x]
            t = (x, y)
            if c in SYM:
                ents[t] = {'kind': 'belt', 'dir': SYM[c]}
            elif c in UG:
                d, io = UG[c]
                ents[t] = {'kind': 'ug', 'dir': d, 'io': io}
            elif c == 'S':
                if x + 1 >= len(row) or row[x + 1] != 's':
                    raise SimError(f'S without s at {t}')
                sid += 1
                ents[t] = {'kind': 'splitter', 'dir': 0, 'half': 'L', 'id': sid}
                ents[(x + 1, y)] = {'kind': 'splitter', 'dir': 0, 'half': 'R', 'id': sid}
                x += 1
            elif c == 'K':
                if y + 1 >= h or len(rows[y + 1]) <= x or rows[y + 1][x] != 'k':
                    raise SimError(f'K without k below at {t}')
                sid += 1
                ents[t] = {'kind': 'splitter', 'dir': 1, 'half': 'L', 'id': sid}
                ents[(x, y + 1)] = {'kind': 'splitter', 'dir': 1, 'half': 'R', 'id': sid}
            elif c == 'J':
                if y == 0 or len(rows[y - 1]) <= x or rows[y - 1][x] != 'j':
                    raise SimError(f'J without j above at {t}')
                sid += 1
                ents[t] = {'kind': 'splitter', 'dir': 3, 'half': 'L', 'id': sid}
                ents[(x, y - 1)] = {'kind': 'splitter', 'dir': 3, 'half': 'R', 'id': sid}
            elif c in 'kj':
                pass  # second half, placed with K / J
            elif c == 's':
                raise SimError(f'stray s at {t}')
            elif c != '.':
                raise SimError(f'unknown symbol {c!r} at {t}')
            x += 1
    inputs = [(x, h - 1) for x in range(w) if (x, h - 1) in ents]
    outputs = [(x, 0) for x in range(w) if (x, 0) in ents]
    for p in inputs + outputs:
        e = ents[p]
        if e['kind'] != 'belt' or e['dir'] != 0:
            raise SimError(f'port {p} must be a north belt')
    return ents, inputs, outputs, (w, h)


def outputs_into(ents, src, dst):
    """Does the entity at src push items into tile dst?"""
    e = ents.get(src)
    if not e:
        return False
    if e['kind'] == 'belt' or (e['kind'] == 'ug' and e['io'] == 'out') or e['kind'] == 'splitter':
        return add(src, e['dir']) == dst
    return False


def is_curve(ents, t):
    e = ents[t]
    d = e['dir']
    behind = outputs_into(ents, add(t, opp(d)), t)
    sides = sum(1 for s in (left(d), right(d)) if outputs_into(ents, add(t, s), t))
    return (not behind) and sides == 1


def ug_partner(ents, t):
    e = ents[t]
    d = e['dir']
    for k in range(1, UG_MAX + 1):
        q = add(t, d, k)
        o = ents.get(q)
        if o and o['kind'] == 'ug' and o['dir'] in (d, opp(d)):
            if o['io'] == 'out' and o['dir'] == d:
                return q
            raise SimError(f'underground at {t} blocked by underground at {q}')
    raise SimError(f'underground entrance at {t} has no exit')


def enter(ents, src, d, lane, errors):
    """Items on `lane` of an entity at src moving in direction d leave into
    the next tile. Returns the receiving node (tile, lane) or None (blocked
    / empty tile)."""
    t = add(src, d)
    e = ents.get(t)
    if e is None:
        return None
    k = e['kind']
    if k == 'belt':
        dt = e['dir']
        if dt == d:
            return (t, lane)
        if dt == opp(d):
            errors.append(f'head-on belts {src}->{t}')
            return None
        if is_curve(ents, t):
            return (t, lane)
        # side-load: src is on the left or right of t
        return (t, L if add(t, left(dt)) == src else R)
    if k == 'ug':
        if e['io'] == 'in' and e['dir'] == d:
            return (t, lane)
        errors.append(f'bad feed into underground at {t} from {src}')
        return None
    if k == 'splitter':
        if e['dir'] == d:
            return (t, lane)
        errors.append(f'side feed into splitter at {t} from {src}')
        return None
    return None


def build_graph(ents, sources, sinks):
    """Return edges: node -> list of (node, weight) and the splitter groups."""
    errors = []
    edges = {}
    split_groups = {}  # id -> {'halves': [tiles], 'dir': d}
    for t, e in ents.items():
        if e['kind'] == 'splitter':
            g = split_groups.setdefault(e['id'], {'halves': [], 'dir': e['dir']})
            g['halves'].append(t)
    for t, e in ents.items():
        for lane in (L, R):
            n = (t, lane)
            if t in sinks:
                edges[n] = []
                continue
            k = e['kind']
            if k == 'belt' or (k == 'ug' and e['io'] == 'out'):
                nxt = enter(ents, t, e['dir'], lane, errors)
                edges[n] = [(nxt, 1)] if nxt else []
            elif k == 'ug':
                p = ug_partner(ents, t)
                edges[n] = [((p, lane), 1)]
            elif k == 'splitter':
                edges[n] = ('split', e['id'], lane)
    return edges, split_groups, errors


def solve(ents, sources, sinks, inject):
    """inject: dict node -> amount. Returns dict sink_tile -> [left, right]
    plus diagnostics."""
    edges, groups, errors = build_graph(ents, sources, sinks)
    # resolve splitter outgoing candidates
    split_out = {}
    for sid, g in groups.items():
        for lane in (L, R):
            outs = []
            for h in g['halves']:
                nxt = enter(ents, h, g['dir'], lane, errors)
                if nxt:
                    outs.append(nxt)
            split_out[(sid, lane)] = outs

    def succ(n):
        v = edges.get(n, [])
        if isinstance(v, tuple):
            return split_out[(v[1], v[2])]
        return [m for m, _ in v]

    # liveness: can reach a sink
    nodes = list(edges.keys())
    live = {n for n in nodes if n[0] in sinks}
    changed = True
    while changed:
        changed = False
        for n in nodes:
            if n not in live and any(m in live for m in succ(n)):
                live.add(n)
                changed = True

    def out_edges(n):
        v = edges.get(n, [])
        if isinstance(v, tuple):
            outs = [m for m in split_out[(v[1], v[2])] if m in live]
            return [(m, 1.0 / len(outs)) for m in outs] if outs else []
        return [(m, float(w)) for m, w in v]

    # floats: loop-backs converge geometrically, exact fractions would blow up
    mass = {n: float(a) for n, a in inject.items()}
    absorbed = {}
    stuck = 0.0
    for _ in range(200000):
        if not mass or sum(mass.values()) < 1e-13:
            break
        new = {}
        for n, a in mass.items():
            if n[0] in sinks:
                absorbed[n] = absorbed.get(n, 0) + a
                continue
            oe = out_edges(n)
            if not oe:
                stuck += a
                continue
            for m, w in oe:
                new[m] = new.get(m, 0) + a * w
        mass = new
    residual = sum(mass.values(), 0.0)
    res = {s: [0.0, 0.0] for s in sinks}
    for (t, lane), a in absorbed.items():
        res[t][lane] += a
    return res, stuck, residual, errors


def check_balancer(ents, inputs, outputs, lane_balance, label, quiet=False):
    """Every input lane must reach every output equally; with lane_balance,
    every output lane equally."""
    m = len(outputs)
    ok = True
    msgs = []
    for i in inputs:
        for lane in (L, R):
            res, stuck, residual, errors = solve(ents, inputs, set(outputs), {(i, lane): 1})
            if errors:
                ok = False
                msgs.extend(sorted(set(errors)))
            # loops converge geometrically: allow a tiny residual
            if stuck > 1e-9 or residual > 1e-6:
                ok = False
                msgs.append(f'input {i} lane {lane}: stuck={float(stuck):.4f} residual={float(residual):.2e}')
            for o in outputs:
                tot = float(res[o][0] + res[o][1])
                if abs(tot - 1 / m) > 1e-6:
                    ok = False
                    msgs.append(f'input {i} lane {lane} -> output {o}: {tot:.4f} (want {1/m:.4f})')
                if lane_balance:
                    for ol in (L, R):
                        v = float(res[o][ol])
                        if abs(v - 1 / (2 * m)) > 1e-6:
                            ok = False
                            msgs.append(f'input {i} lane {lane} -> output {o} lane {ol}: {v:.4f}')
    if not quiet:
        print(('PASS ' if ok else 'FAIL ') + label)
        for s in msgs[:12]:
            print('   ', s)
    return ok, msgs


def load_templates(path):
    from lupa import lua52
    lua = lua52.LuaRuntime(unpack_returned_tuples=True)
    with open(path) as f:
        tbl = lua.execute(f.read())
    out = []
    for i in range(1, len(tbl) + 1):
        t = tbl[i]
        grid = [t.grid[j] for j in range(1, len(t.grid) + 1)]
        out.append({'name': t.name, 'inputs': t.inputs, 'outputs': t.outputs,
                    'lane': bool(t.lane), 'grid': grid})
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, '..', 'scripts', 'templates.lua')
    all_ok = True
    for t in load_templates(path):
        try:
            ents, ins, outs, _ = parse_grid(t['grid'])
        except SimError as ex:
            print('FAIL', t['name'], ex)
            all_ok = False
            continue
        if len(ins) != t['inputs'] or len(outs) != t['outputs']:
            print('FAIL', t['name'], f'ports {len(ins)}x{len(outs)} != declared')
            all_ok = False
            continue
        ok, _ = check_balancer(ents, ins, outs, t['lane'],
                               f"{t['name']:9s} {len(ins)}->{len(outs)}" + (' (lanes)' if t['lane'] else ''))
        all_ok &= ok
        # every subset of inputs must still balance (we build fewer inputs)
        if ok and len(ins) > 1:
            from itertools import combinations
            for k in range(1, len(ins)):
                for sub in combinations(ins, k):
                    sub_ents = {p: e for p, e in ents.items() if p not in set(ins) - set(sub)}
                    ok2, msgs = check_balancer(sub_ents, list(sub), outs, t['lane'], '', quiet=True)
                    if not ok2:
                        print(f'   FAIL subset {sub}: {msgs[:2]}')
                        all_ok = False
    print('ALL TEMPLATES OK' if all_ok else 'SOME TEMPLATES FAILED')
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
