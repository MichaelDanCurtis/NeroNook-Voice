#!/usr/bin/env python3
"""Exercise the signed executable without audio, secrets or assistant execution."""
import importlib.util, json, os, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('kit', root/'Tools/nook.py'); kit = importlib.util.module_from_spec(spec); spec.loader.exec_module(kit)
app = Path((root/'build/latest-package.txt').read_text().strip())
bins = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip())
kit.protocol_test(root, app, bins, json.loads((root/'Resources/NookPlugin.json').read_text()), kit.FEATURES)
