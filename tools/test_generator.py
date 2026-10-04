#!/usr/bin/env python3
"""Checks every generated balancer (scripts/generator.lua) with the lane flow
simulator: each input lane must reach every output equally.

python3 tools/test_generator.py           n, m = 1..8 (yellow) + a few others
python3 tools/test_generator.py --all     n, m = 1..16 and other underground ranges
python3 tools/test_generator.py --show    also print the grids
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim  # noqa: E402
from lupa import lua52  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SHOW = '--show' in sys.argv
ALL = '--all' in sys.argv

lua = lua52.LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = "{ROOT}/?.lua;" .. package.path')
gen = lua.eval('require("scripts.generator")')


def grid_of(n, m, ug):
    t = gen.template(n, m, ug)
    if not t:
        return None, gen.last_error
    return [t.grid[i] for i in range(1, len(t.grid) + 1)], None


def check(n, m, ug):
    grid, err = grid_of(n, m, ug)
    if grid is None:
        print(f'FAIL {n}->{m} ug={ug}: not generated: {err}')
        return False
    sim.UG_MAX = ug
    try:
        ents, ins, outs, (w, h) = sim.parse_grid(grid)
    except sim.SimError as ex:
        print(f'FAIL {n}->{m} ug={ug}: {ex}')
        return False
    if len(ins) != n or len(outs) != m:
        print(f'FAIL {n}->{m} ug={ug}: ports {len(ins)}->{len(outs)}')
        return False
    ok, msgs = sim.check_balancer(ents, ins, outs, False, '', quiet=True)
    print(('PASS' if ok else 'FAIL') + f' {n}->{m} ug={ug}: {w}x{h}')
    for s in msgs[:6]:
        print('    ', s)
    if SHOW or not ok:
        for r in grid:
            print('      ' + r)
    return ok


def main():
    t0 = time.time()
    ok = True
    top = 16 if ALL else 8
    for n in range(1, top + 1):
        for m in range(1, top + 1):
            if (n, m) != (1, 1):
                ok &= check(n, m, 5)
    extra = [(8, 8, 2), (8, 8, 3), (8, 8, 4), (5, 7, 3), (7, 3, 2), (16, 16, 5), (12, 10, 4), (3, 16, 5)]
    if ALL:
        extra += [(8, 8, 8), (16, 16, 3), (16, 16, 9)]
    for n, m, ug in extra:
        ok &= check(n, m, ug)
    print(f'{time.time() - t0:.1f}s')
    print('ALL GENERATED BALANCERS OK' if ok else 'GENERATOR TESTS FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
