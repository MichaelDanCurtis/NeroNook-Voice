"""Expose existing native token alignment as word metadata; no decoding changes.
Pinned upstream input; fails closed if the dependency changes. MIT source.
"""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
p=root/'Workers/Diarization/.build/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Models/Nemo/NemoAlignment.swift'
s=p.read_text()
marker='// Nero Voice: preserve word timing for speaker-turn alignment.'
if marker not in s:
    assert hashlib.sha256(p.read_bytes()).hexdigest()=='c391497e8f52f7b452234671a1d80e79ff1a5af9126cfef183ba2f479cee9793','Upstream alignment source changed; review before applying patch'
    start=s.index('        sentences.map {',s.index('public var segments:'))
    end=s.index('\n    }\n}',start)
    replacement='''        // Nero Voice: preserve word timing for speaker-turn alignment.
        sentences.map { sentence in
            var words: [[String: Any]] = []
            var text = ""
            var start = 0.0, end = 0.0
            func flush() {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    words.append(["text": text, "start": start, "end": max(start + 0.01, end)])
                }
            }
            for token in sentence.tokens {
                if token.text.first?.isWhitespace == true && !text.isEmpty { flush(); text = "" }
                if text.isEmpty { start = token.start }
                text += token.text; end = token.end
            }
            flush()
            return ["text": sentence.text, "start": sentence.start, "end": sentence.end, "words": words]
        }'''
    p.chmod(p.stat().st_mode | 0o200)
    p.write_text(s[:start]+replacement+s[end:])
print('Word-timing patch ready')
