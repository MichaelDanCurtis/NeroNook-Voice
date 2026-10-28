"""One local Nemotron model, independent room/call streaming states. No network."""
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / 'Vendor'))
import mlx.core as mx
import numpy as np
from mlx_audio.vad.models.nemotron_diarization.config import ModelConfig
from mlx_audio.vad.models.nemotron_diarization.nemotron_diarization import Model
from stream_protocol import emit, packets
from activity import SpeakerActivity


def main():
    folder = Path(sys.argv[1])
    config = ModelConfig.from_dict(json.loads((folder / 'config.json').read_text()))
    # Same checkpoint, bounded shorter context for provisional live attribution.
    # The default longer-context file pass remains available after recording.
    config.modules_config.chunk_len = 32
    config.modules_config.chunk_right_context = 8
    model = Model(config)
    model.load_weights(str(folder / 'model.safetensors'), strict=True)
    model.eval()
    mx.eval(model.parameters())
    output = sys.stdout.buffer
    states, ends, pending, activities = {}, {}, {}, {}
    count = 0

    def feed(track, data, final=False):
        nonlocal count
        if track not in states:
            states[track] = model.init_streaming_state()
            activities[track] = SpeakerActivity()
        state = states[track]
        result, state = model.feed(mx.array(data), state, final=final)
        states[track] = state
        spans, through = activities[track].feed(np.array(result.speaker_probs), final=final)
        through = min(ends.get(track, 0) / 16000, through)
        spans = [dict(start=s['start'], end=min(through, s['end']), speaker=s['speaker'])
                 for s in spans if min(through, s['end']) > s['start']]
        count += len(spans)
        if count > 100000:
            raise ValueError('Speaker segment limit')
        emit(output, type='spans', track=track, through=through, spans=spans)

    def add(track, data):
        pending[track] = np.concatenate((pending.get(track, np.empty(0, dtype=np.float32)), data))
        if pending[track].size >= 40960:
            feed(track, pending.pop(track))

    emit(output, type='ready')
    for track, start, raw in packets(sys.stdin.buffer):
        pcm = np.frombuffer(raw, dtype='<f4').copy()
        if not np.isfinite(pcm).all():
            raise ValueError('Invalid speaker samples')
        position = int(round(start * 16000))
        previous = ends.get(track, 0)
        while previous < position:
            zeros = min(16000, position - previous)
            previous += zeros
            ends[track] = previous
            add(track, np.zeros(zeros, dtype=np.float32))
        skip = max(0, previous - position)
        if skip < pcm.size:
            pcm = pcm[skip:]
            ends[track] = previous + pcm.size
            add(track, pcm)
        emit(output, type='ack')
    for track in sorted(ends):
        feed(track, pending.pop(track, np.empty(0, dtype=np.float32)), final=True)
    emit(output, type='closed')


if __name__ == '__main__':
    main()
