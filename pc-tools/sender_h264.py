# sender_h264.py -- push an H.264 live stream to the phone (VCU1 over USB/iproxy)
# Portrait 1080x1920, 30 fps, full range, no B-frames, low latency.
# Usage:
#   python3 sender_h264.py                      test pattern
#   python3 sender_h264.py HOST PORT SOURCE     SOURCE = video file, or any ffmpeg input URL
#                                               (e.g. udp://0.0.0.0:5000, srt://..., rtmp://...)
import os, select, shutil, socket, struct, subprocess, sys, time

HOST = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 28765
SRC = sys.argv[3] if len(sys.argv) > 3 else ''
PROFILE = sys.argv[4] if len(sys.argv) > 4 else 'high'   # high / main / baseline
LEVEL = sys.argv[5] if len(sys.argv) > 5 else ''          # e.g. 4.2
W_ARG = sys.argv[6] if len(sys.argv) > 6 else ''          # optional test size, e.g. 720x1280
MBPS = int(sys.argv[7]) if len(sys.argv) > 7 else 25       # video bitrate in Mbit/s (USB can take 30+)
PRESET = sys.argv[8] if len(sys.argv) > 8 else 'faster'   # x264 speed: veryfast < faster < fast < medium (slower = nicer, more CPU)
W, H, FPS = 1080, 1920, 30
if W_ARG:
    W, H = [int(x) for x in W_ARG.split('x')]
FF = shutil.which('ffmpeg') or r'D:\Codex\ivcam\ffmpeg.exe'

def packet(ftype, flags, payload, seq, ts):
    return b'VCU1' + struct.pack('>BBHIIQ', 1, ftype, flags, len(payload), seq & 0xFFFFFFFF, ts) + payload

def avcc_record(sps, pps):
    rec = bytearray([1]) + sps[1:4] + bytes([0xFF, 0xE1])
    rec += struct.pack('>H', len(sps)) + sps + bytes([1]) + struct.pack('>H', len(pps)) + pps
    return bytes(rec)

def split_nals(buf, final=False):
    """Return (list of NAL payloads without start code, leftover bytes).
    final=False: the last NAL is kept as leftover (it may be incomplete).
    final=True : the buffer ends exactly at a packet boundary, so the last NAL is complete too."""
    starts = []
    i = 0
    n = len(buf)
    while True:
        j = buf.find(b'\x00\x00\x01', i)
        if j < 0:
            break
        starts.append(j)
        i = j + 3
    if final and starts:
        bounds = starts + [len(buf)]
        leftover = b''
    else:
        bounds = starts
        leftover = None
    if len(bounds) < 2:
        return [], buf
    nals = []
    for a, b in zip(bounds, bounds[1:]):
        nal = buf[a + 3:b]
        while nal.endswith(b'\x00'):
            nal = nal[:-1]
        if nal:
            nals.append(nal)
    if leftover is not None:
        return nals, leftover
    return nals, buf[starts[-1] - (1 if starts[-1] > 0 and buf[starts[-1] - 1] == 0 else 0):]

def start_ffmpeg():
    if SRC:
        live = '://' in SRC
        inputs = (['-fflags', '+nobuffer', '-flags', '+low_delay'] if live else ['-re', '-stream_loop', '-1']) + ['-i', SRC]
    else:
        inputs = ['-re', '-f', 'lavfi', '-i', 'testsrc2=size=%dx%d:rate=%d' % (W, H, FPS)]
    cmd = [FF, '-hide_banner', '-loglevel', 'error'] + inputs + [
        '-vf', 'scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,fps=%d,format=yuvj420p' % (W, H, W, H, FPS),
        '-c:v', 'libx264', '-preset', PRESET, '-tune', 'zerolatency',
        '-profile:v', PROFILE, '-pix_fmt', 'yuvj420p', '-color_range', 'pc',
        ] + (['-level', LEVEL] if LEVEL else []) + [
        '-g', str(FPS), '-keyint_min', str(FPS), '-sc_threshold', '0', '-bf', '0',
        '-b:v', '%dM' % MBPS, '-maxrate', '%dM' % (MBPS * 8 // 7), '-bufsize', '%dM' % max(2, MBPS * 2 // 5),
        '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
        '-x264-params', 'sliced-threads=0:slices=1:repeat-headers=1:fullrange=on:aud=0:sync-lookahead=0',
        '-an', '-f', 'h264', 'pipe:1']
    return subprocess.Popen(cmd, stdout=subprocess.PIPE)

def connect():
    while True:
        try:
            s = socket.create_connection((HOST, PORT), timeout=5)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.settimeout(None)
            print('connected %s:%d' % (HOST, PORT), flush=True)
            return s
        except OSError as e:
            print('waiting phone...', e, flush=True)
            time.sleep(3)

def read_packet(proc, buf):
    """Read what ffmpeg wrote. Returns (data, final). final=True means the data ends at a packet boundary
    (nothing more arrived for 4 ms), so the last frame can be sent right away instead of waiting for the next one."""
    if os.name == 'nt':                       # select() cannot watch pipes on Windows: old behaviour
        return proc.stdout.read(65536), False
    fd = proc.stdout.fileno()
    data = os.read(fd, 262144)
    if not data:
        return b'', False
    while select.select([fd], [], [], 0.004)[0]:
        more = os.read(fd, 262144)
        if not more:
            break
        data += more
    return data, True

def main():
    proc = start_ffmpeg()
    s = connect()
    seq = frames = 0
    sps = pps = None
    config_sent = False
    last_hb = 0.0
    t0 = time.time()
    buf = b''
    last_frame_at = 0.0
    gap_max = 0.0
    gap_late = 0
    send_max = 0.0
    while True:
        chunk, final = read_packet(proc, buf)
        if not chunk:
            print('ffmpeg ended', flush=True)
            return
        buf += chunk
        nals, buf = split_nals(buf, final)
        try:
            for nal in nals:
                t = nal[0] & 0x1F
                if t == 7: sps = nal
                elif t == 8: pps = nal
                elif t in (1, 5):
                    if not config_sent:
                        if t != 5 or not sps or not pps:
                            continue          # wait for the first key frame
                        s.sendall(packet(1, 0, avcc_record(sps, pps), seq, 0)); seq += 1
                        config_sent = True
                        print('config sent', flush=True)
                    t_a = time.perf_counter()
                    if last_frame_at:
                        gap = (t_a - last_frame_at) * 1000.0
                        gap_max = max(gap_max, gap)
                        if gap > 50: gap_late += 1
                    last_frame_at = t_a
                    s.sendall(packet(2, 1 if t == 5 else 0, b'\x00\x00\x00\x01' + nal, seq,
                                     int(frames * 1000000 / FPS)))
                    send_max = max(send_max, (time.perf_counter() - t_a) * 1000.0)
                    seq += 1; frames += 1
            now = time.time()
            if now - last_hb >= 1.0:
                s.sendall(packet(5, 0, b'', seq, int(now * 1000000))); seq += 1
                last_hb = now
                print('frames=%d rate=%.1f fps  frame-gap max=%dms late(>50ms)=%d  send max=%dms'
                      % (frames, frames / (now - t0), gap_max, gap_late, send_max), flush=True)
                gap_max = 0.0; gap_late = 0; send_max = 0.0
        except OSError as e:
            print('disconnected:', e, '- reconnecting', flush=True)
            try: s.close()
            except OSError: pass
            s = connect()
            config_sent = False; seq = 0

if __name__ == '__main__':
    main()
