#!/usr/bin/env python3
"""Link scanner integration tests against an unsigned Development app build.

Usage: python3 tests/run-tree-builder.py /path/to/Objects-normal/arm64
Build first with xcodebuild ... -configuration Development CODE_SIGNING_ALLOWED=NO.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
objects = [str(p.resolve()) for p in Path(sys.argv[1]).glob('*.o') if p.name != 'main.o']
if not any(Path(p).name == 'TreeBuilder.o' for p in objects):
    sys.exit('Expected an Xcode Objects-normal/<architecture> directory containing TreeBuilder.o')
with tempfile.TemporaryDirectory(prefix='gp-tree-test-') as tmp:
    executable = str(Path(tmp) / 'tree-test')
    subprocess.run([
        'clang', '-fmodules', '-fblocks', '-g',
        *[f'-I{p}' for p in (repo / 'src').iterdir() if p.is_dir()],
        str(repo / 'tests/tree-builder.m'), *objects,
        '-framework', 'Cocoa', '-framework', 'UniformTypeIdentifiers',
        '-framework', 'Carbon', '-framework', 'QuartzCore', '-o', executable,
    ], check=True)
    subprocess.run([executable], check=True)
