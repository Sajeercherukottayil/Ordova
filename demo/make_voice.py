# Generates the narration for the demo video with edge-tts (Microsoft's online
# neural voices; needs internet and `pip install edge-tts`).
#
#   python demo/make_voice.py <ffmpeg.exe> <out folder>
#
# Captions are read from integration_test/demo_video_test.dart so the spoken
# lines always match the script. Writes <out>/voice/NN.mp3, <out>/voice.json
# (line -> length in ms, read by the test) and <out>/voice_files.json.
import asyncio, json, pathlib, re, subprocess, sys

import edge_tts

VOICE = 'en-IN-NeerjaNeural'
RATE = '+0%'

INTRO = ("Meet Ordova: order taking and kitchen management for a small café. "
         "It runs on the shop's own Wi-Fi, with no internet, no account, and no monthly cost.")
OUTRO = ("That's Ordova. Live table status, a kitchen board with sound alerts, ready alerts for waiters, "
         "orders you can edit or cancel, easy billing, and a daily sales report. All on your café's local Wi-Fi.")

# Spoken wording where the on-screen caption doesn't read well aloud.
SPOKEN = {
    'Paid by UPI, and the table is free again': 'Paid by U.P.I., and the table is free again.',
    'The kitchen beeps again, and the ticket is marked EDITED': 'The kitchen beeps again, and the ticket is marked as edited.',
    'T3 wants a samosa too. It is not cooked yet, so the waiter edits the order':
        'Table 3 wants a samosa too. It is not cooked yet, so the waiter edits the order.',
    'Now the cook starts the T3 ticket…': 'Now the cook starts the table 3 ticket',
}

ff, out = sys.argv[1], pathlib.Path(sys.argv[2])
src = pathlib.Path(__file__).resolve().parent.parent / 'integration_test' / 'demo_video_test.dart'
captions = [m.replace("\\'", "'") for m in re.findall(r"say\('((?:[^'\\]|\\.)*)'", src.read_text(encoding='utf8'))]
lines = {'intro': INTRO, 'outro': OUTRO, **{c: SPOKEN.get(c, c.replace('…', '')) for c in captions}}


def length_ms(path):
    err = subprocess.run([ff, '-i', str(path)], capture_output=True, text=True).stderr
    h, m, s = re.search(r'Duration: (\d+):(\d+):([\d.]+)', err).groups()
    return round((int(h) * 3600 + int(m) * 60 + float(s)) * 1000)


async def main():
    (out / 'voice').mkdir(parents=True, exist_ok=True)
    lengths, files = {}, {}
    for i, (key, text) in enumerate(lines.items()):
        path = out / 'voice' / f'{i:02}.mp3'
        await edge_tts.Communicate(text, VOICE, rate=RATE).save(str(path))
        lengths[key], files[key] = length_ms(path), str(path)
        print(f'{lengths[key]:6} ms  {text}')
    (out / 'voice.json').write_text(json.dumps(lengths, ensure_ascii=False, indent=1), encoding='utf8')
    (out / 'voice_files.json').write_text(json.dumps(files, ensure_ascii=False, indent=1), encoding='utf8')


asyncio.run(main())
