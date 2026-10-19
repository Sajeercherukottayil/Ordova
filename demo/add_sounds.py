# Mixes the alert tones (recreated from lib/services/alerts.dart) and, if
# demo/make_voice.py was run, the narration into the recorded demo video.
#
#   python demo/add_sounds.py <ffmpeg.exe> <out folder>
#
# Reads <out>/ordova_demo_silent.mp4 and <out>/sounds.json, writes <out>/ordova_demo.mp4.
import json, math, os, re, struct, subprocess, sys, wave

ff, d = sys.argv[1], sys.argv[2]
RATE = 44100


def tone(freqs, sec):
    per = round(RATE * sec)
    out = []
    for f in freqs:
        for i in range(per):
            fade = min(1.0, min(i / 400, (per - i) / 1200))
            out.append(0 if f == 0 else round(math.sin(2 * math.pi * f * i / RATE) * 0.6 * fade * 32767))
    return out


tones = {'new_order': tone([880, 0, 880, 0, 1175], 0.13), 'ready': tone([1046, 1318, 1568], 0.18)}
events = json.load(open(f'{d}/sounds.json', encoding='utf8'))
err = subprocess.run([ff, '-i', f'{d}/ordova_demo_silent.mp4'], capture_output=True, text=True).stderr
h, m, s = re.search(r'Duration: (\d+):(\d+):([\d.]+)', err).groups()
duration = int(h) * 3600 + int(m) * 60 + float(s)

# Beeps go into one WAV; it also sets the length of the soundtrack.
track = [0] * int(RATE * duration)
for e in events:
    if e['kind'] not in tones:
        continue
    start = int(e['ms'] / 1000 * RATE)
    for i, v in enumerate(tones[e['kind']]):
        if start + i < len(track):
            track[start + i] = max(-32767, min(32767, track[start + i] + int(v * 0.7)))
with wave.open(f'{d}/sounds.wav', 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(struct.pack(f'<{len(track)}h', *track))

# Each narration line starts when the test logged it.
files_path = f'{d}/voice_files.json'
files = json.load(open(files_path, encoding='utf8')) if os.path.exists(files_path) else {}
voices = [(files[e['line']], e['ms']) for e in events if e['kind'] == 'voice' and e['line'] in files]

inputs = ['-i', f'{d}/ordova_demo_silent.mp4', '-i', f'{d}/sounds.wav']
chains, labels = [], ['[1:a]']
for n, (path, ms) in enumerate(voices):
    inputs += ['-i', path]
    chains.append(f'[{n + 2}:a]aresample={RATE},adelay={ms}:all=1,volume=1.6[v{n}]')
    labels.append(f'[v{n}]')
graph = ';'.join(chains + [f"{''.join(labels)}amix=inputs={len(labels)}:normalize=0:duration=first,alimiter=limit=0.95[a]"])

subprocess.run([ff, '-v', 'error', '-y', *inputs, '-filter_complex', graph, '-map', '0:v', '-map', '[a]',
                '-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart',
                f'{d}/ordova_demo.mp4'], check=True)
print(f'{len(voices)} narration lines, {sum(e["kind"] in tones for e in events)} alert tones')
