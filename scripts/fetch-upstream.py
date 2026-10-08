"""Fetch pinned, attributed upstream reader sources. Run only when updating vendor files."""
import json
import pathlib
import subprocess
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]
READEST = 'f74a19d39e2badf81125f42a85c54adae26c7048'

checkout = ROOT / '.upstream' / 'readest'
if not checkout.exists():
    subprocess.run(['git', 'clone', '--depth', '1', '--filter=blob:none', '--sparse',
                    'https://github.com/readest/readest.git', str(checkout)], check=True)
subprocess.run(['git', '-C', str(checkout), 'fetch', '--depth', '1', 'origin', READEST], check=True)
subprocess.run(['git', '-C', str(checkout), 'checkout', '--detach', READEST], check=True)
subprocess.run(['git', '-C', str(checkout), 'sparse-checkout', 'set',
                'apps/readest-app/src/utils', 'apps/readest-app/src/__tests__/fixtures/crengine',
                'apps/readest-app/src/__tests__/fixtures/data'], check=True)
foliate = subprocess.check_output(['git', '-C', str(checkout), 'ls-tree', READEST,
                                  'packages/foliate-js'], text=True).split()[2]
dest = ROOT / 'vendor' / 'readest'
dest.mkdir(parents=True, exist_ok=True)
paths = ['LICENSE', 'apps/readest-app/src/utils/xcfi.ts', 'apps/readest-app/src/utils/md5.ts']
paths += ['apps/readest-app/src/__tests__/fixtures/crengine/sample-alice.json',
          'apps/readest-app/src/__tests__/fixtures/data/sample-alice.epub']
for path in paths:
    target = dest / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((checkout / path).read_bytes())
foliate_checkout = ROOT / '.upstream' / 'foliate-js'
if not foliate_checkout.exists():
    subprocess.run(['git', 'clone', '--depth', '1', 'https://github.com/readest/foliate-js.git',
                    str(foliate_checkout)], check=True)
subprocess.run(['git', '-C', str(foliate_checkout), 'fetch', '--depth', '1', 'origin', foliate], check=True)
subprocess.run(['git', '-C', str(foliate_checkout), 'checkout', '--detach', foliate], check=True)
shutil.copytree(foliate_checkout, ROOT / 'vendor' / 'foliate-js', dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('.git', 'node_modules'))
(ROOT / 'vendor' / 'revisions.json').write_text(json.dumps({'readest': READEST, 'foliate-js': foliate}, indent=2) + '\n')
(ROOT / 'LICENSE').write_bytes((dest / 'LICENSE').read_bytes())
print(f'Vendored Readest {READEST} and its Foliate revision {foliate}')
