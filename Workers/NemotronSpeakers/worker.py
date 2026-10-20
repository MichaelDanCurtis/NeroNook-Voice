"""Pinned local Nemotron 3 speaker worker. No hub/network/model-code loading."""
import json
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent / 'Vendor'))
import mlx.core as mx
import numpy as np
from mlx_audio.vad.models.nemotron_diarization.config import ModelConfig
from mlx_audio.vad.models.nemotron_diarization.nemotron_diarization import Model

def main():
    model_path, audio_path, output_path = map(Path, sys.argv[1:])
    size = audio_path.stat().st_size
    if size <= 0 or size % 4 or size > 16000 * 4 * 3600 * 4:
        raise ValueError('Invalid PCM length')
    model = Model(ModelConfig.from_dict(json.loads((model_path/'config.json').read_text())))
    model.load_weights(str(model_path/'model.safetensors'), strict=True)
    model.eval()
    mx.eval(model.parameters())
    state = model.init_streaming_state()
    segments = []
    def collect(result):
        duration = size / 64000
        for s in result.segments:
            start, end = max(0, float(s.start)), min(duration, float(s.end))
            if end > start:
                segments.append(dict(start=start, end=end, speaker=int(s.speaker)))
        if len(segments) > 100000:
            raise ValueError('Speaker segment limit')
    # State and speaker identities persist across all chunks, including final flush.
    with audio_path.open('rb') as audio:
        while block := audio.read(16000 * 4 * 5):
            result, state = model.feed(mx.array(np.frombuffer(block, dtype='<f4').copy()), state)
            collect(result)
            print('progress', audio.tell() / size, flush=True)
        result, state = model.feed(mx.zeros((0,)), state, final=True)
        collect(result)
    temporary = output_path.with_suffix('.tmp')
    temporary.write_text(json.dumps(segments))
    os.replace(temporary, output_path)
if __name__ == '__main__':
    main()
