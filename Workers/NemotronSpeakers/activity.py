"""Bounded, deterministic speaker activity with hysteresis and edge padding.

No model or identity inference here. Each speaker is independent; overlap is
retained. Four 10 ms frames of lookahead permit onset padding without revising
already committed live intervals. Offline and live use this exact implementation.
"""
import numpy as np


class SpeakerActivity:
    def __init__(self, speakers=8, onset=0.5, offset=0.5, pad_frames=4, stride=0.01):
        if not (1 <= speakers <= 8 and 0 <= offset <= onset <= 1 and
                type(pad_frames) is int and 0 <= pad_frames <= 100 and stride > 0):
            raise ValueError('Invalid activity policy')
        self.speakers, self.onset, self.offset = speakers, onset, offset
        self.pad, self.stride = pad_frames, stride
        self.active = np.zeros(speakers, dtype=bool)
        self.last = np.full(speakers, -pad_frames-1, dtype=np.int64)
        self.pending = []
        self.frames = self.committed = 0
        self.finished = False

    def feed(self, probabilities, final=False):
        if self.finished:
            raise ValueError('Speaker activity already finished')
        p = np.asarray(probabilities, dtype=np.float32)
        if p.ndim != 2 or p.shape[1] != self.speakers or not np.isfinite(p).all() or np.any((p < 0) | (p > 1)):
            raise ValueError('Invalid speaker probabilities')
        masks = []
        start = self.committed
        for row in p:
            previous = self.active.copy()
            self.active = np.where(self.active, row >= self.offset, row >= self.onset)
            onset = self.active & ~previous
            if onset.any():
                for mask in self.pending:
                    mask[onset] = True
            self.last[self.active] = self.frames
            self.pending.append((self.frames - self.last <= self.pad).copy())
            self.frames += 1
            if len(self.pending) > self.pad:
                masks.append(self.pending.pop(0))
        if final:
            masks.extend(self.pending); self.pending = []; self.finished = True
        self.committed += len(masks)
        spans = []
        if masks:
            masks = np.asarray(masks)
            for speaker in range(self.speakers):
                enabled = np.pad(masks[:, speaker].astype(np.int8), (1, 1))
                edges = np.diff(enabled)
                for a, b in zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)):
                    spans.append(dict(start=(start+int(a))*self.stride,
                                      end=(start+int(b))*self.stride, speaker=speaker))
        spans.sort(key=lambda s: (s['start'], s['speaker']))
        return spans, self.committed*self.stride
