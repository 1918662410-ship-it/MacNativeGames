#!/usr/bin/env python3
"""Build Ventura graphics objects and run standalone tests; no game files needed."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--window', action='store_true', help='also show the three-second presentation test')
a = ap.parse_args()
root = Path(__file__).resolve().parents[2]
repo = root.parents[1]
out = a.output.resolve()
if out == repo or repo in out.parents:
    ap.error('output must be outside the source checkout')
out.mkdir(parents=True, exist_ok=True)
gfx = root / 'third_party/d2r_gfx/gfx/nvn'
flags = ['-fobjc-arc', '-O1', '-mmacosx-version-min=13.0', '-DDM_NVN_M3=1', '-Werror=unguarded-availability-new', '-I'+str(gfx), '-I'+str(gfx/'include')]
results = []
def run(name, cmd):
    p = subprocess.run([str(x) for x in cmd], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out/(name+'.log')).write_text(p.stdout)
    results.append(dict(name=name, exit=p.returncode, log=name+'.log'))
    print(('PASS' if p.returncode == 0 else 'BLOCKED' if p.returncode == 77 else 'FAIL')+' '+name, flush=True)
    return p.returncode == 0
sources = sorted(gfx.glob('*.[cm]')) + sorted((gfx.parent/'tex').glob('*.[cm]'))
for source in sources:
    run('object-'+source.name, ['xcrun', 'clang', *flags, '-std=gnu11', '-c', source, '-o', out/(source.name+'.o')])
# These three units require validated game-generated headers. Do not fabricate headers.
recipe = (root/'Makefile').read_text().split('build/totk-native-v143-m3:',1)[1].split('\n',2)[1]
runtime = [Path(x) for x in recipe.split() if x.startswith('runtime/') and x.endswith(('.c','.m','.S'))]
skipped = {'loader.c','romfs.c','shared_font.c'}
for source in runtime:
    if source.name in skipped: continue
    run('runtime-'+source.name, ['xcrun','clang',*flags,'-DTOTK_GAME_V143=1','-Iruntime','-I/opt/homebrew/opt/opus/include/opus','-I/opt/homebrew/opt/libvpx/include','-c',source,'-o',out/('runtime-'+source.name+'.o')])
run('launcher', ['xcrun','clang',*flags,'-DTOTK_GAME_V143=1','-Iruntime','app/launcher.m','-framework','AppKit','-framework','GameController','-o',out/'game-launcher'])
for name, source in [('compat-probe',Path(__file__).with_name('probe.m')),('buffer-registry',Path(__file__).with_name('buffer_registry.m')),('selective-texture',Path(__file__).with_name('selective_texture.m')),('selective-buffer',Path(__file__).with_name('selective_buffer.m')),('selective-compute',Path(__file__).with_name('selective_compute.m')),('metal-semantics',root/'tests/metal_semantics/probe.m')]+([('window-probe',Path(__file__).with_name('window.m'))] if a.window else []):
    if run(name+'-build', ['xcrun','clang',*flags,source,gfx/'m3_compat.m','-framework','Metal','-framework','Cocoa','-framework','QuartzCore','-o',out/name]):
        run(name, [out/name,*([out/'render.png'] if name == 'window-probe' else ['--gpu'] if name == 'buffer-registry' else [])])
        if name == 'selective-buffer':
            run('selective-buffer-precise', [out/name,'2'])
if run('upload-direct-build', ['xcrun','clang',*flags,Path(__file__).with_name('upload_direct.m'),gfx/'m3_compat.m',gfx/'nvn_tex.c',gfx.parent/'tex/nvn_deswizzle.c',gfx.parent/'tex/nvn_deswizzle_gpu.m','-framework','Metal','-framework','Foundation','-framework','QuartzCore','-o',out/'upload-direct']):
    run('upload-direct', [out/'upload-direct'])
if run('resource-use-cache-build', ['xcrun','clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(gfx),Path(__file__).with_name('resource_use_cache.c'),'-o',out/'resource-use-cache']):
    run('resource-use-cache', [out/'resource-use-cache'])
summary = dict(graphics_sources=len(sources), runtime_sources=len(runtime)-len(skipped), skipped_generated_units=sorted(skipped), game_started=False, checks=results)
(out/'verification.json').write_text(json.dumps(summary,indent=2))
sys.exit(0 if all(x['exit']==0 for x in results) else 1)
