# Bundled Nemotron 3 diarization

This is a private worker inside the independently installed Voice plugin. The
host has no Python or model dependency. The app bundles a compressed, signed
CPython/MLX runtime; Prepare speakers expands it into Voice-owned storage.
No pip, server, remote code or model downloads run during inference.

The vendored MLX Audio subset is unchanged source from
`94c7716212b2228f178d2f9c7619a591fd1b0b78` (MIT; see Vendor/LICENSE):
base.py, dsp.py, audio_io.py, Sortformer config/model, and Nemotron diarization
config/model. Only those imports are used. The worker directly constructs the
Nemotron model with strict weight loading and carries AOSC state through every
five-second input block, followed by final lookahead flush. It consumes 16 kHz
mono float32 PCM produced from saved meeting CAF; it cannot capture audio.

Build runtime (Apple Silicon; developer tooling only):

```
uv python install 3.12.11
mkdir -p build/speaker-runtime
cp -R "$HOME/.local/share/uv/python/cpython-3.12.11-macos-aarch64-none/." build/speaker-runtime/
uv pip install --python build/speaker-runtime/bin/python3.12 --target build/speaker-runtime/lib/python3.12/site-packages mlx==0.31.1 numpy==2.4.3
```

The package script checks dependency versions, removes build tools/tests/caches,
signs every Mach-O with the same stable app identity and records the archive's
SHA-256. It keeps Python's license and wheel distribution metadata/licenses.
The app verifies that hash before extraction. No independent user Python is
consulted. Public release still requires the normal license/notarization review.


The Voice-owned `activity.py` postprocessor adds 40 ms edge coverage at the
existing 0.50 threshold. It delays commitment by four frames and flushes the tail;
no earlier timestamp is revised. Both file and streaming workers use it with
independent per-track state. This is outside the unchanged vendored model source.
The more aggressive development hysteresis setting was rejected and is not used.
Production invocation uses isolated Python (`-I -B`); worker imports explicitly
resolve only its bundled directory and Vendor. Tests include the exact isolated
process path and independently scored public human audio; this is not full-corpus
or live-call qualification.
