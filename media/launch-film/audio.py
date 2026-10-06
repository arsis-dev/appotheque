"""Soundtrack for the film: a soft pad and arpeggio, plus sound effects placed on the cues exported by render.mjs.

Standard library only. Usage: python3 audio.py [folder]  ->  <folder>/audio.wav (default folder: out)
The folder holds sfx.json and music.json (duration, bpm, start of the arpeggio, pulse), both written by render.mjs.
Music and effects share one key (D major) and one room (a light reverb) so they read as one piece.
"""
import json, math, os, random, struct, sys, wave
from array import array

SR = 44100
random.seed(7)
DIR = sys.argv[1] if len(sys.argv) > 1 else 'out'
cues = json.load(open(os.path.join(DIR, 'sfx.json')))
MUSIC = json.load(open(os.path.join(DIR, 'music.json'))) if os.path.exists(os.path.join(DIR, 'music.json')) else {}
DURATION = float(MUSIC.get('duration', 21.0))
N = int(SR * DURATION)
music = array('f', [0.0]) * N
fx = array('f', [0.0]) * N
TAU = 2 * math.pi


def note(n):  # MIDI note to frequency
    return 440.0 * 2 ** ((n - 69) / 12)


def add(buf, start, samples, gain=1.0):
    i0 = int(start * SR)
    for i, v in enumerate(samples):
        j = i0 + i
        if 0 <= j < N:
            buf[j] += v * gain


def env(i, n, attack, release):
    a = int(attack * SR); r = int(release * SR)
    if i < a: return i / max(1, a)
    if i > n - r: return max(0.0, (n - i) / max(1, r))
    return 1.0


# ---------- music: D major, ~92 bpm ----------
BEAT = 60 / float(MUSIC.get('bpm', 92))
ARP_START = float(MUSIC.get('start', 3.7))
# Dmaj9, Bm7, Gmaj7, Aadd9 for 8 beats each, looped; the last 3 s resolve on Dmaj9.
CYCLE = [[50, 57, 61, 64, 66], [47, 54, 57, 62, 66], [43, 50, 54, 59, 62], [45, 52, 57, 59, 64]]
CHORDS, b = [], 0
while (b + 8) * BEAT < DURATION - 3:
    CHORDS.append((b, CYCLE[len(CHORDS) % 4])); b += 8
CHORDS.append((max(b, (DURATION - 3.2) / BEAT), [50, 57, 61, 64, 69]))


def pad(freqs, dur, amp=0.05):
    n = int(dur * SR); out = []
    det = [random.uniform(-.0025, .0025) for _ in freqs]
    for i in range(n):
        t = i / SR; e = env(i, n, 1.2, 1.4); v = 0.0
        for f, d in zip(freqs, det):
            ph = TAU * f * (1 + d) * t
            v += math.sin(ph) + .28 * math.sin(2 * ph) + .1 * math.sin(3 * ph)
        out.append(v * e * amp / len(freqs))
    return out


for idx, (b, notes) in enumerate(CHORDS):
    start = b * BEAT
    end = CHORDS[idx + 1][0] * BEAT if idx + 1 < len(CHORDS) else DURATION
    add(music, max(0, start - .4), pad([note(n) for n in notes], end - start + 1.2), 1.0)
    # low root
    root = note(notes[0] - 12); n = int((end - start + .8) * SR)
    add(music, start, [math.sin(TAU * root * i / SR) * env(i, n, .3, .8) * .05 for i in range(n)])


def pluck(f, dur=.45, amp=.05):
    n = int(dur * SR)
    return [(math.sin(TAU * f * i / SR) + .35 * math.sin(TAU * 2 * f * i / SR)) * math.exp(-7 * i / SR) * min(1, i / 60) * amp for i in range(n)]


# Arpeggio enters with the second scene and stops before the outro swell.
step = BEAT / 2
t = ARP_START
while t < DURATION - 3.2:
    beat = t / BEAT
    chord = [c for c in CHORDS if c[0] <= beat][-1][1]
    k = int(round((t - ARP_START) / step))
    f = note(chord[[1, 3, 2, 4][k % 4]] + 12)
    add(music, t, pluck(f, amp=.035 if k % 2 else .045))
    t += step

if MUSIC.get('pulse'):
    t = ARP_START
    while t < DURATION - 3.2:
        n = int(.25 * SR)
        add(music, t, [math.sin(TAU * (55 * math.exp(-18 * i / SR) + 42) * i / SR) * math.exp(-11 * i / SR) * .16 for i in range(n)])
        t += BEAT

# ---------- sound effects, tuned to D major ----------
def tick(gain):
    f = note(random.choice([86, 88, 90, 93])); n = int(.06 * SR)
    return [math.sin(TAU * f * i / SR) * math.exp(-60 * i / SR) * .22 * gain for i in range(n)]


def click(gain):
    n = int(.05 * SR); out = []
    for i in range(n):
        e = math.exp(-120 * i / SR)
        out.append((random.uniform(-1, 1) * .5 + math.sin(TAU * 2400 * i / SR) * .5) * e * .5 * gain)
    return out


def chime(gain):
    base = note(74); n = int(1.6 * SR); out = []
    for i in range(n):
        t2 = i / SR
        v = (math.sin(TAU * base * t2) * math.exp(-3 * t2) + .5 * math.sin(TAU * base * 2.0 * t2) * math.exp(-4.5 * t2)
             + .25 * math.sin(TAU * base * 3.01 * t2) * math.exp(-6 * t2) + .3 * math.sin(TAU * note(78) * t2) * math.exp(-3.5 * t2))
        out.append(v * min(1, i / 80) * .16 * gain)
    return out


def whoosh(gain):
    n = int(.55 * SR); out = []; lp = 0.0
    for i in range(n):
        x = i / n; cutoff = .02 + .25 * math.sin(math.pi * x)
        lp += cutoff * (random.uniform(-1, 1) - lp)
        out.append(lp * math.sin(math.pi * x) ** 2 * .55 * gain)
    return out


def blip(gain):
    n = int(.32 * SR); out = []
    for i in range(n):
        t2 = i / SR; f = note(57) if t2 < .14 else note(56)  # a semitone drop: "not the same"
        out.append(math.sin(TAU * f * t2) * env(i, n, .005, .12) * .13 * gain)
    return out


def hit(gain):
    n = int(.5 * SR); out = []; lp = 0.0
    for i in range(n):
        t2 = i / SR; f = 110 * math.exp(-9 * t2) + 48
        lp += .08 * (random.uniform(-1, 1) - lp)
        out.append((math.sin(TAU * f * t2) * math.exp(-7 * t2) * .55 + lp * math.exp(-30 * t2) * 1.2) * .28 * gain)
    return out


def swell(gain):
    n = int(1.4 * SR); out = []; lp = 0.0
    for i in range(n):
        x = i / n; lp += (.01 + .1 * x) * (random.uniform(-1, 1) - lp)
        out.append(lp * x ** 2 * (1 - max(0, x - .9) * 10) * .5 * gain)
    return out


def key(gain):
    n = int(.045 * SR); out = []; lp = 0.0
    for i in range(n):
        lp += .35 * (random.uniform(-1, 1) - lp)
        out.append((lp * .8 + math.sin(TAU * 1800 * i / SR) * .25) * math.exp(-140 * i / SR) * .5 * gain)
    return out


def keycap(gain):
    n = int(.18 * SR); out = []; lp = 0.0
    for i in range(n):
        t2 = i / SR; lp += .18 * (random.uniform(-1, 1) - lp)
        out.append((lp * math.exp(-60 * t2) * 1.1 + math.sin(TAU * (180 * math.exp(-20 * t2) + 90) * t2) * math.exp(-22 * t2) * .6) * .45 * gain)
    return out


def pop(gain):
    f0 = note(random.choice([74, 76, 78, 81])); n = int(.12 * SR)
    return [math.sin(TAU * f0 * (1 + .6 * math.exp(-40 * i / SR)) * i / SR) * math.exp(-28 * i / SR) * .2 * gain for i in range(n)]


SOUNDS = {'key': key, 'keycap': keycap, 'pop': pop, 'tick': tick, 'click': click, 'chime': chime, 'whoosh': whoosh, 'blip': blip, 'hit': hit, 'swell': swell}
for t0, name, gain in cues:
    s = SOUNDS[name](gain)
    # A swell rises into its cue; everything else starts on it.
    add(fx, t0 - (1.3 if name == 'swell' else 0), s)


# ---------- one shared room: a light Schroeder reverb on the effects, less on the music ----------
def reverb(buf, mix):
    out = array('f', buf)
    combs = [(1557, .80), (1617, .79), (1491, .78), (1422, .77)]
    acc = array('f', [0.0]) * N
    for d, g in combs:
        line = array('f', [0.0]) * N
        for i in range(N):
            v = buf[i] + (line[i - d] * g if i >= d else 0.0)
            line[i] = v
            acc[i] += v * .25
    for d, g in [(225, .5), (556, .5)]:  # all-pass
        prev = array('f', acc)
        for i in range(N):
            x = prev[i]; y = -g * x + (prev[i - d] if i >= d else 0) + g * (acc[i - d] if i >= d else 0)
            acc[i] = y
    for i in range(N):
        out[i] = buf[i] + acc[i] * mix
    return out


music = reverb(music, .18)
fx = reverb(fx, .32)

# Fade in/out, mix, soft limit.
mixL = array('f', [0.0]) * N; mixR = array('f', [0.0]) * N
for i in range(N):
    t2 = i / SR
    fade = min(1, t2 / .4) * min(1, (DURATION - t2) / 1.2)
    v = (music[i] * .9 + fx[i]) * fade
    # light stereo width: effects slightly delayed on the right
    vr = (music[i] * .9 + (fx[i - 220] if i >= 220 else 0)) * fade
    mixL[i] = math.tanh(v * 1.4) / 1.4; mixR[i] = math.tanh(vr * 1.4) / 1.4
peak = max(max(abs(x) for x in mixL), max(abs(x) for x in mixR)) or 1
scale = .89 / peak
with wave.open(os.path.join(DIR, 'audio.wav'), 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(struct.pack('<hh', int(mixL[i] * scale * 32767), int(mixR[i] * scale * 32767)) for i in range(N)))
print(os.path.join(DIR, 'audio.wav'), round(DURATION, 1), 's')
