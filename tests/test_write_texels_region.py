"""Region writes into NVN texture storage must equal the whole-level round trip."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GFX = ROOT / 'games/totk/third_party/d2r_gfx/gfx'


class WriteTexelsRegion(unittest.TestCase):
    def test_region_matches_round_trip(self):
        compiler = shutil.which('cc') or shutil.which('clang')
        if not compiler:
            self.skipTest('A C compiler is required for the texel region regression')
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'test-write-texels-region'
            build = subprocess.run(
                [compiler, '-std=gnu11', '-O2', f'-I{GFX}', f'-I{GFX / "nvn"}', f'-I{GFX / "nvn/include"}',
                 str(ROOT / 'tests/test_write_texels_region.c'), str(GFX / 'tex/nvn_deswizzle.c'),
                 str(GFX / 'nvn/nvn_tex.c'), '-o', str(executable)],
                capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS 3000 region checks', result.stdout)


if __name__ == '__main__':
    unittest.main()
