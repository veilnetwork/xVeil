"""Generate synthetic tones, encode real Opus, and frame RTP. No user audio."""
import argparse
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import wave

DURATION = 12
BURSTS = [(1.5, 3.0, 480), (5.0, 6.5, 720), (8.5, 10.0, 960)]


def ogg_packets(data):
    pending = bytearray()
    offset = 0
    while offset < len(data):
        if data[offset:offset + 4] != b'OggS':
            raise ValueError('invalid Ogg fixture')
        count = data[offset + 26]
        segments = data[offset + 27:offset + 27 + count]
        offset += 27 + count
        for length in segments:
            pending.extend(data[offset:offset + length])
            offset += length
            if length < 255:
                yield bytes(pending)
                pending.clear()
    if pending:
        raise ValueError('unfinished Ogg packet')


def generate(destination, ffmpeg='ffmpeg', *, silence=False, packet_ms=20):
    if packet_ms not in (20, 40, 60):
        raise ValueError('unsupported packet duration')
    count = DURATION * 1000 // packet_ms
    with tempfile.TemporaryDirectory(prefix='xveil-tone-fixture-') as directory:
        wav = Path(directory) / 'source.wav'
        ogg = Path(directory) / 'source.ogg'
        with wave.open(str(wav), 'wb') as output:
            output.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
            pcm = bytearray()
            for index in range(DURATION * 48000):
                seconds = index / 48000
                frequency = next((f for a, b, f in BURSTS
                                  if a <= seconds < b), None)
                if silence:
                    frequency = None
                value = 0 if frequency is None else round(
                    0.03 * 32767 * math.sin(2 * math.pi * frequency * seconds))
                pcm.extend(struct.pack('<h', value))
            output.writeframes(pcm)
        subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-y', '-i', str(wav),
                        '-c:a', 'libopus', '-application', 'voip', '-b:a', '32k',
                        '-vbr', 'off', '-frame_duration', str(packet_ms), str(ogg)], check=True)
        opus = list(ogg_packets(ogg.read_bytes()))
    if len(opus) < count + 2 or not opus[0].startswith(b'OpusHead'):
        raise ValueError('unexpected encoded fixture')
    packets = []
    for index, payload in enumerate(opus[2:count + 2]):
        header = struct.pack('!BBHII', 0x80, 111, index,
                             index * packet_ms * 48, 0x02020202)
        packets.append(header + payload)
    destination.write_bytes(b'XVR2' + struct.pack('<II', len(packets), packet_ms) + b''.join(
        struct.pack('<I', len(packet)) + packet for packet in packets))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--silence', action='store_true')
    parser.add_argument('--packet-ms', type=int, choices=(20, 40, 60), default=20)
    args = parser.parse_args()
    generate(args.destination, args.ffmpeg, silence=args.silence,
             packet_ms=args.packet_ms)
