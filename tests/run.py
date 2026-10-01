#!/usr/bin/env python3
"""Run isolated Neovim behavior checks and reproducible latency benchmarks."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
suite = sys.argv[1] if len(sys.argv) > 1 else 'all'
if suite not in {'all', 'regression', 'persistence', 'benchmark', 'syntax'}:
    raise SystemExit('Usage: python3 tests/run.py [all|regression|persistence|benchmark|syntax]')
with tempfile.TemporaryDirectory(prefix='mru-tests-') as name:
    tmp = Path(name).resolve()
    env = dict(os.environ, MRU_REPO=str(repo), MRU_TEST_TMP=str(tmp))
    env.pop('NVIM_APPNAME', None)
    for key in ('CONFIG', 'DATA', 'STATE', 'CACHE'):
        env['XDG_' + key + '_HOME'] = str(tmp / key.lower())
    deps = Path(env.get('MRU_TEST_PLUGINS', str(Path.home() / '.local/share/nvim/lazy')))
    if all((deps / name).is_dir() for name in ('telescope.nvim', 'plenary.nvim')):
        env['MRU_TEST_PLUGINS'] = str(deps)
    else:
        env.pop('MRU_TEST_PLUGINS', None)
        print('Telescope not installed: optional adapter checks skipped.', flush=True)
    def run(name, phase=None):
        args = ['nvim', '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l', str(repo / 'tests' / (name + '.lua'))]
        subprocess.run(args, cwd=repo, env=dict(env, MRU_TEST_PHASE=phase or ''), check=True)
    if suite in {'all', 'syntax'}:
        run('syntax')
    if suite in {'all', 'regression'}:
        run('regression')
    if suite in {'all', 'persistence'}:
        for name in ('project/a.txt', 'other/b.txt'):
            target = tmp / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('fixture\n')
        run('persistence', 'save')
        run('persistence', 'restore')
    if suite == 'benchmark':
        run('benchmark')
