#!/usr/bin/env python3
"""BGM 抗性回归素材生成：语音不动，混入合成 BGM（和弦垫 + 轻打点）。
语音时间轴零改变 => 人工标注 truth 依然有效。

用法：python3 mix_bgm.py <输入 16k mono s16 wav> <输出 wav> [BGM 相对 dB，默认 -18]
结果记录：docs/spikes/results/koubo-01-bgm-regression.md
"""
import math
import random
import struct
import sys
import wave

src, dst = sys.argv[1], sys.argv[2]
bgm_db = float(sys.argv[3]) if len(sys.argv) > 3 else -18.0

with wave.open(src) as w:
    assert w.getnchannels() == 1 and w.getsampwidth() == 2, "需要 16k 单声道 s16 WAV"
    rate = w.getframerate()
    n = w.getnframes()
    speech = struct.unpack(f"<{n}h", w.readframes(n))

speech_rms = math.sqrt(sum(s * s for s in speech) / len(speech))
target_rms = speech_rms * (10 ** (bgm_db / 20))

# 和弦垫：C–Am–F–G 正弦三和音，每和弦 2s，100ms 淡入淡出避免咔哒
chords_hz = [
    [130.8, 164.8, 196.0],
    [110.0, 130.8, 164.8],
    [87.3, 110.0, 130.8],
    [98.0, 123.5, 146.8],
]
chord_len = 2 * rate
bgm = [0.0] * n
for i in range(n):
    chord = chords_hz[(i // chord_len) % len(chords_hz)]
    pos = (i % chord_len) / chord_len
    env = min(1.0, pos / 0.05, (1 - pos) / 0.05)
    t = i / rate
    bgm[i] = env * sum(math.sin(2 * math.pi * f * t) for f in chord) / len(chord)

# 轻打点：每 0.5s 一个 60ms 衰减白噪脉冲（专测 VAD 抗瞬态）
random.seed(7)
hit = int(0.06 * rate)
for start in range(0, n, rate // 2):
    for j in range(min(hit, n - start)):
        bgm[start + j] += 0.9 * (1 - j / hit) * (random.random() * 2 - 1)

bgm_rms = math.sqrt(sum(s * s for s in bgm) / len(bgm))
gain = target_rms / bgm_rms
mixed = [max(-32768, min(32767, int(s + gain * b))) for s, b in zip(speech, bgm)]

with wave.open(dst, "w") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(struct.pack(f"<{len(mixed)}h", *mixed))

print(f"speech_rms={speech_rms:.1f} bgm_gain={gain:.3f} → {dst}")
