#!/usr/bin/env python3
"""Imports balancers from a Factorio blueprint book string into
scripts/book_templates.lua, keeping only designs the flow simulator proves
balanced.

python3 tools/import_book.py BOOK.txt            import + write report
python3 tools/import_book.py BOOK.txt --report   only print the report

Every blueprint labelled "N to M" (or "N_M_...") is:
  1. decoded and turned so items flow north (template frame),
  2. checked for N input belts (no feeder) and M output belts (nothing in
     front),
  3. given straight port belts: inputs are extended south to a common last
     row, outputs north to a common first row,
  4. verified by the simulator with all inputs, and with every subset of
     inputs (designs that only balance with all inputs are marked exact).
Designs that fail any step are reported and skipped.
"""
import base64
import json
import os
import re
import sys
import zlib
from itertools import combinations

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
DIRS = sim.DIRS
BELT_CH = {0: '^', 1: '>', 2: 'v', 3: '<'}
UG_CH = {(0, 'in'): 'D', (0, 'out'): 'U', (1, 'in'): 'e', (1, 'out'): 'E',
         (2, 'in'): 'd', (2, 'out'): 'u', (3, 'in'): 'w', (3, 'out'): 'W'}
TIER = {'transport-belt': 'belt', 'fast-transport-belt': 'belt', 'express-transport-belt': 'belt',
        'turbo-transport-belt': 'belt',
        'splitter': 'splitter', 'fast-splitter': 'splitter', 'express-splitter': 'splitter',
        'turbo-splitter': 'splitter',
        'underground-belt': 'ug', 'fast-underground-belt': 'ug', 'express-underground-belt': 'ug',
        'turbo-underground-belt': 'ug'}


def decode(path):
    s = open(path).read().strip()
    return json.loads(zlib.decompress(base64.b64decode(s[1:])))


def walk(node, trail=()):
    if 'blueprint_book' in node:
        b = node['blueprint_book']
        for c in b.get('blueprints', []):
            yield from walk(c, trail + (b.get('label', ''),))
    elif 'blueprint' in node:
        yield trail, node['blueprint']


def counts(label):
    m = re.match(r'\s*(\d+)\s*(?:to|_)\s*(\d+)', label or '')
    return (int(m.group(1)), int(m.group(2))) if m else None


def to_ents(bp):
    """-> {tile: sim entity} in blueprint coordinates, or raise ValueError"""
    v2 = bp.get('version', 0) >= (2 << 48)   # 2.0 strings use 16 directions
    ents = {}
    sid = 0
    for e in bp.get('entities', []):
        kind = TIER.get(e['name'])
        if not kind:
            raise ValueError(f'unsupported entity {e["name"]}')
        raw = e.get('direction', 0)
        d = raw // 4 if v2 else raw // 2
        x, y = e['position']['x'], e['position']['y']
        if kind == 'splitter':
            sid += 1
            if d % 2 == 0:
                tiles = [(int(x - 0.5 + 100) - 100, int(y + 100) - 100), (int(x + 0.5 + 100) - 100, int(y + 100) - 100)]
            else:
                tiles = [(int(x + 100) - 100, int(y - 0.5 + 100) - 100), (int(x + 100) - 100, int(y + 0.5 + 100) - 100)]
            # left half relative to the facing direction
            lx, ly = DIRS[(d + 3) % 4]
            a, b = tiles
            left = a if (a[0] - b[0], a[1] - b[1]) == (lx, ly) else b
            for t in tiles:
                ents[t] = {'kind': 'splitter', 'dir': d, 'half': 'L' if t == left else 'R', 'id': sid}
        else:
            t = (int(x + 100) - 100, int(y + 100) - 100)
            if kind == 'belt':
                ents[t] = {'kind': 'belt', 'dir': d}
            else:
                ents[t] = {'kind': 'ug', 'dir': d, 'io': 'in' if e.get('type') == 'input' else 'out'}
    return ents


def rotate(ents, k):
    """rotate the whole layout clockwise k times"""
    out = {}
    for (x, y), e in ents.items():
        for _ in range(k):
            x, y = -y, x
        n = dict(e)
        n['dir'] = (e['dir'] + k) % 4
        out[(x, y)] = n
    return out


def opp(d):
    return (d + 2) % 4


def pushes(e):
    return e['kind'] in ('belt', 'splitter') or (e['kind'] == 'ug' and e['io'] == 'out')


def find_ports(ents, n, m):
    """input / output tiles: belts first; if the counts don't match the
    label, splitter halves with nothing behind / in front count too (they
    get a belt added)"""
    fed = set()
    for t, e in ents.items():
        if pushes(e):
            fed.add(sim.add(t, e['dir']))
    ins = [t for t, e in ents.items() if e['kind'] == 'belt' and t not in fed]
    outs = [t for t, e in ents.items() if e['kind'] == 'belt' and sim.add(t, e['dir']) not in ents]
    ents = dict(ents)
    if len(ins) != n:
        extra = [t for t, e in ents.items() if e['kind'] == 'splitter' and t not in fed
                 and sim.add(t, opp(e['dir'])) not in ents]
        if len(ins) + len(extra) == n:
            for t in extra:
                b = sim.add(t, opp(ents[t]['dir']))
                ents[b] = {'kind': 'belt', 'dir': ents[t]['dir']}
                ins.append(b)
    if len(outs) != m:
        extra = [t for t, e in ents.items() if e['kind'] == 'splitter' and sim.add(t, e['dir']) not in ents]
        if len(outs) + len(extra) == m:
            for t in extra:
                f = sim.add(t, ents[t]['dir'])
                ents[f] = {'kind': 'belt', 'dir': ents[t]['dir']}
                outs.append(f)
    return ents, ins, outs


def straighten(ents, ins, outs):
    """extend input belts south / output belts north to common port rows;
    returns (ents, new input tiles, new output tiles) or raises ValueError"""
    ents = dict(ents)
    new_ins, new_outs = [], []
    for t in ins:
        e = ents[t]
        if e['dir'] == 2:
            raise ValueError('input faces against the flow')
        if e['dir'] != 0:
            # feed it from the south instead of from behind: it becomes a curve
            behind = sim.add(t, 2)
            if behind in ents:
                raise ValueError('no room to feed a sideways input')
            ents[behind] = {'kind': 'belt', 'dir': 0}
            t = behind
        new_ins.append(t)
    for t in outs:
        e = ents[t]
        if e['dir'] == 2:
            raise ValueError('output faces against the flow')
        if e['dir'] != 0:
            front = sim.add(t, e['dir'])
            ents[front] = {'kind': 'belt', 'dir': 0}
            t = front
        new_outs.append(t)
    ys = [t[1] for t in ents]
    bottom, top = max(ys), min(ys)
    # the port rows must hold nothing but ports
    if any(t[1] == bottom for t in ents if t not in new_ins):
        bottom += 1
    if any(t[1] == top for t in ents if t not in new_outs):
        top -= 1
    fin, fout = [], []
    for t in new_ins:
        x, y = t
        for yy in range(y + 1, bottom + 1):
            if (x, yy) in ents:
                raise ValueError('input blocked on its way to the port row')
            ents[(x, yy)] = {'kind': 'belt', 'dir': 0}
        fin.append((x, bottom))
    for t in new_outs:
        x, y = t
        for yy in range(y - 1, top - 1, -1):
            if (x, yy) in ents:
                raise ValueError('output blocked on its way to the port row')
            ents[(x, yy)] = {'kind': 'belt', 'dir': 0}
        fout.append((x, top))
    return ents, fin, fout


def to_grid(ents):
    xs = [t[0] for t in ents]
    ys = [t[1] for t in ents]
    x0, y0 = min(xs), min(ys)
    w, h = max(xs) - x0 + 1, max(ys) - y0 + 1
    rows = [['.'] * w for _ in range(h)]
    for (x, y), e in ents.items():
        c = '.'
        if e['kind'] == 'belt':
            c = BELT_CH[e['dir']]
        elif e['kind'] == 'ug':
            c = UG_CH[(e['dir'], e['io'])]
        else:
            d, half = e['dir'], e['half']
            c = {0: 'Ss', 1: 'Kk', 3: 'Jj', 2: 'Qq'}[d][0 if half == 'L' else 1]
        rows[y - y0][x - x0] = c
    return [' '.join(r) for r in rows]


def ug_len(ents):
    longest = 0
    for t, e in ents.items():
        if e['kind'] == 'ug' and e['io'] == 'in':
            for k in range(1, 20):
                o = ents.get(sim.add(t, e['dir'], k))
                if o and o['kind'] == 'ug' and o['dir'] == e['dir'] and o['io'] == 'out':
                    longest = max(longest, k)
                    break
    return longest


def convert(bp):
    """-> dict(grid, inputs, outputs, exact, ug) or raise ValueError"""
    nm = counts(bp.get('label'))
    if not nm:
        raise ValueError('no "N to M" in the label')
    n, m = nm
    ents = to_ents(bp)
    splitters = [e['dir'] for e in ents.values() if e['kind'] == 'splitter']
    if not splitters:
        flow = max(range(4), key=lambda d: sum(1 for e in ents.values() if e['dir'] == d))
    else:
        flow = max(range(4), key=lambda d: splitters.count(d))
    ents = rotate(ents, (4 - flow) % 4)
    ents, ins, outs = find_ports(ents, n, m)
    if (len(ins), len(outs)) != (n, m):
        raise ValueError(f'found {len(ins)} -> {len(outs)} belts, label says {n} -> {m}')
    ents, ins, outs = straighten(ents, ins, outs)
    grid = to_grid(ents)
    sim.UG_MAX = 10
    g_ents, g_ins, g_outs, _ = sim.parse_grid(grid)
    if (len(g_ins), len(g_outs)) != (n, m):
        raise ValueError(f'port rows hold {len(g_ins)} -> {len(g_outs)}')
    ok, msgs = sim.check_balancer(g_ents, g_ins, g_outs, False, '', quiet=True)
    if not ok:
        raise ValueError('not balanced: ' + '; '.join(msgs[:2]))
    exact = False
    if n <= 6:
        subsets = [sub for k in range(1, n) for sub in combinations(g_ins, k)]
    else:  # all would take long: single inputs and all-but-one
        subsets = [(t,) for t in g_ins] + [tuple(u for u in g_ins if u != t) for t in g_ins]
    for sub in subsets:
        if True:
            sub_ents = {p: e for p, e in g_ents.items() if p not in set(g_ins) - set(sub)}
            ok2, _ = sim.check_balancer(sub_ents, list(sub), g_outs, False, '', quiet=True)
            if not ok2:
                exact = True
                break
    return {'grid': grid, 'inputs': n, 'outputs': m, 'exact': exact, 'ug': ug_len(g_ents),
            'w': len(grid[0].split()), 'h': len(grid)}


def main():
    path = sys.argv[1]
    report_only = '--report' in sys.argv
    book = decode(path)
    good, bad = [], []
    seen = set()
    for trail, bp in walk(book):
        label = bp.get('label', '')
        name = ' / '.join([t for t in trail[1:] if t] + [label])
        if len(bp.get('entities', [])) > 400:
            bad.append((name, 'too big for the planner'))
            continue
        print(f'... {name}', file=sys.stderr, flush=True)
        try:
            r = convert(bp)
        except (ValueError, sim.SimError, KeyError) as ex:
            bad.append((name, str(ex)))
            continue
        k = tuple(r['grid'])
        if k in seen:
            continue
        seen.add(k)
        r['name'] = name
        good.append(r)
    for r in good:
        print(f"OK   {r['name']:60s} {r['inputs']}->{r['outputs']} {r['w']}x{r['h']} ug={r['ug']}"
              + (' exact' if r['exact'] else ''))
    for name, why in bad:
        print(f'SKIP {name:60s} {why}')
    print(f'{len(good)} balanced designs, {len(bad)} skipped')
    if report_only:
        return 0
    # keep the smallest few designs per count and underground length
    best = {}
    for r in good:
        best.setdefault((r['inputs'], r['outputs']), []).append(r)
    out = ['-- Generated by tools/import_book.py from a balancer blueprint book;',
           '-- every design here was proved balanced by tools/sim.py. Do not edit.',
           'return {']
    kept = 0
    for (n, m), lst in sorted(best.items()):
        lst.sort(key=lambda r: (r['w'] * r['h'], r['ug']))
        chosen, ugs = [], set()
        for r in lst:
            # one per underground length needed (yellow/red/blue reach), max 3
            if r['ug'] in ugs or len(chosen) >= 3:
                continue
            if any(c['ug'] <= r['ug'] for c in chosen):
                continue
            ugs.add(r['ug'])
            chosen.append(r)
        for i, r in enumerate(chosen):
            kept += 1
            out.append('  {')
            out.append(f'    name = "book", source = {json.dumps(r["name"], ensure_ascii=False)},')
            out.append(f'    inputs = {n}, outputs = {m},' + (' exact = true,' if r['exact'] else ''))
            out.append('    grid = {')
            for row in r['grid']:
                out.append(f'      "{row}",')
            out.append('    },')
            out.append('  },')
    out.append('}')
    with open(os.path.join(ROOT, 'scripts', 'book_templates.lua'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    print(f'wrote scripts/book_templates.lua: {kept} designs')
    return 0


if __name__ == '__main__':
    sys.exit(main())
