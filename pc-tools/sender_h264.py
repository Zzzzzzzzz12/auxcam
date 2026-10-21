# sender_h264.py -- push an H.264 live stream to the phone (VCU1 over USB/iproxy)
# ffmpeg encodes and hands the stream over as RTP packets on localhost, so the end of every frame is known EXACTLY
# (RTP marker bit). Nothing is ever cut in half, and a frame is sent the moment it is complete.
# Portrait 1080x1920, 30 fps, full range, no B-frames, low latency.
# Usage:
#   python3 sender_h264.py                      test pattern
#   python3 sender_h264.py HOST PORT SOURCE     SOURCE = video file, or any ffmpeg input URL
#                                               (e.g. udp://0.0.0.0:5000, srt://..., rtmp://...)
import base64, os, random, re, shutil, socket, struct, subprocess, sys, tempfile, time

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
FF = os.environ.get('AUX_FFMPEG') or shutil.which('ffmpeg') or r'D:\Codex\ivcam\ffmpeg.exe'
# AUX_ENC = x264 (software, best quality per bit, heavy CPU) | vt (Mac hardware encoder, light CPU) | auto (default)
# AUX_HWDEC = 1 lets ffmpeg decode the SOURCE video with the Mac hardware as well (video files / big streams)
ENC = os.environ.get('AUX_ENC', 'auto').lower()
HWDEC = os.environ.get('AUX_HWDEC', '0') == '1'

def has_encoder(name):
    try:
        out = subprocess.run([FF, '-hide_banner', '-encoders'], capture_output=True, text=True, timeout=20).stdout
        return name in out
    except Exception:
        return False

if ENC == 'auto':
    ENC = 'vt' if (sys.platform == 'darwin' and has_encoder('h264_videotoolbox')) else 'x264'
print('encoder: %s%s' % ('VideoToolbox hardware' if ENC == 'vt' else 'x264 software', ' + hardware decode' if HWDEC else ''), flush=True)

def packet(ftype, flags, payload, seq, ts):
    return b'VCU1' + struct.pack('>BBHIIQ', 1, ftype, flags, len(payload), seq & 0xFFFFFFFF, ts) + payload

def avcc_record(sps, pps):
    rec = bytearray([1]) + sps[1:4] + bytes([0xFF, 0xE1])
    rec += struct.pack('>H', len(sps)) + sps + bytes([1]) + struct.pack('>H', len(pps)) + pps
    return bytes(rec)

def start_ffmpeg(port, sdp_path):
    pre = ['-hwaccel', 'videotoolbox'] if HWDEC else []
    if SRC:
        live = '://' in SRC
        inputs = pre + (['-fflags', '+nobuffer', '-flags', '+low_delay'] if live else ['-re', '-stream_loop', '-1']) + ['-i', SRC]
    else:
        inputs = ['-re', '-f', 'lavfi', '-i', 'testsrc2=size=%dx%d:rate=%d' % (W, H, FPS)]
    size_filter = 'scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,fps=%d' % (W, H, W, H, FPS)
    tags = ['-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709']
    if ENC == 'vt':
        # Hardware encoder: almost no CPU, so the Mac cannot starve and stall the stream.
        # Standard (limited) range is fine: the phone decoder converts to full range by itself.
        video = ['-vf', size_filter + ',format=nv12',
                 '-c:v', 'h264_videotoolbox', '-profile:v', PROFILE if PROFILE in ('baseline', 'main', 'high') else 'high',
                 '-realtime', '1', '-allow_sw', '0', '-g', str(FPS), '-bf', '0',
                 '-b:v', '%dM' % MBPS, '-maxrate', '%dM' % (MBPS * 8 // 7)] + tags
    else:
        video = ['-vf', size_filter + ',format=yuvj420p',
                 '-c:v', 'libx264', '-preset', PRESET, '-tune', 'zerolatency',
                 '-profile:v', PROFILE, '-pix_fmt', 'yuvj420p', '-color_range', 'pc'] + \
                (['-level', LEVEL] if LEVEL else []) + \
                ['-g', str(FPS), '-keyint_min', str(FPS), '-sc_threshold', '0', '-bf', '0',
                 '-b:v', '%dM' % MBPS, '-maxrate', '%dM' % (MBPS * 8 // 7), '-bufsize', '%dM' % max(2, MBPS * 2 // 5)] + tags + \
                ['-x264-params', 'sliced-threads=0:slices=1:repeat-headers=1:fullrange=on:aud=0:sync-lookahead=0']
    out = ['-an', '-f', 'rtp', '-sdp_file', sdp_path, 'rtp://127.0.0.1:%d?pkt_size=1400' % port]
    cmd = [FF, '-hide_banner', '-loglevel', 'error'] + inputs + video + out
    return subprocess.Popen(cmd)

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

def drain(us):
    """Throw away whatever piled up in the socket while the phone was not connected (old pictures must not be replayed)."""
    us.settimeout(0)
    try:
        while True:
            us.recv(65535)
    except (BlockingIOError, socket.timeout, OSError):
        pass
    us.settimeout(1.0)

def sps_pps_from_sdp(path):
    """ffmpeg writes the stream description (SDP) when it starts; it carries SPS/PPS as sprop-parameter-sets."""
    try:
        txt = open(path, 'r', errors='ignore').read()
    except OSError:
        return None, None
    m = re.search(r'sprop-parameter-sets=([A-Za-z0-9+/=]+),([A-Za-z0-9+/=]+)', txt)
    if not m:
        return None, None
    try:
        return base64.b64decode(m.group(1)), base64.b64decode(m.group(2))
    except Exception:
        return None, None

class RtpFrames:
    """Turns RTP packets (H.264, RFC 6184) back into whole frames. A frame ends at the packet with the marker bit.
    If a packet went missing inside a frame, that frame is dropped, and so is everything until the next key frame."""
    def __init__(self):
        self.nals = []
        self.fu = None
        self.expect = None
        self.bad = False
        self.need_idr = True
        self.dropped = 0
        self.sps = None
        self.pps = None

    def feed(self, pkt):
        """Returns (slices, is_key) when a frame is complete and good, else None."""
        if len(pkt) < 13:
            return None
        b0, b1 = pkt[0], pkt[1]
        if (b0 >> 6) != 2:
            return None
        marker = b1 >> 7
        seq = (pkt[2] << 8) | pkt[3]
        if self.expect is not None and seq != self.expect:
            self.bad = True
            self.fu = None
        self.expect = (seq + 1) & 0xFFFF
        off = 12 + 4 * (b0 & 0x0F)
        if b0 & 0x10 and len(pkt) >= off + 4:
            off += 4 + 4 * ((pkt[off + 2] << 8) | pkt[off + 3])
        pl = pkt[off:]
        if len(pl) < 2:
            return self._end(marker)
        t = pl[0] & 0x1F
        if 1 <= t <= 23:
            self.nals.append(bytes(pl))
        elif t == 24:                                  # STAP-A: several small NALs in one packet
            i = 1
            while i + 2 <= len(pl):
                n = (pl[i] << 8) | pl[i + 1]
                i += 2
                if i + n > len(pl):
                    self.bad = True
                    break
                self.nals.append(bytes(pl[i:i + n]))
                i += n
        elif t == 28:                                  # FU-A: one big NAL cut into pieces
            start, end = pl[1] >> 7, (pl[1] >> 6) & 1
            if start:
                self.fu = bytearray([(pl[0] & 0xE0) | (pl[1] & 0x1F)])
            if self.fu is None:
                self.bad = True
            else:
                self.fu += pl[2:]
                if end:
                    self.nals.append(bytes(self.fu))
                    self.fu = None
        return self._end(marker)

    def _end(self, marker):
        if not marker:
            return None
        nals, bad = self.nals, self.bad
        self.nals, self.fu, self.bad = [], None, False
        slices, key = [], False
        for n in nals:
            t = n[0] & 0x1F
            if t == 7: self.sps = n
            elif t == 8: self.pps = n
            elif t in (1, 5):
                slices.append(n)
                if t == 5: key = True
        if not slices:
            return None
        if bad:
            self.dropped += 1
            self.need_idr = True
            return None
        if self.need_idr:
            if not key:
                self.dropped += 1
                return None
            self.need_idr = False
        return slices, key

def main():
    sdp_path = os.path.join(tempfile.gettempdir(), 'auxcam_stream_%d.sdp' % os.getpid())
    try: os.remove(sdp_path)
    except OSError: pass
    us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    us.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    us.bind(('127.0.0.1', 0))
    us.settimeout(1.0)
    port = us.getsockname()[1]
    proc = start_ffmpeg(port, sdp_path)
    s = connect()
    drain(us)
    rtp = RtpFrames()
    drop_rate = float(os.environ.get('AUX_TEST_DROP', '0'))     # test only: randomly lose packets
    seq = frames = 0
    config = False
    last_at = 0.0
    gap_max = 0.0
    gap_late = 0
    send_max = 0.0
    last_hb = 0.0
    t0 = time.time()
    while True:
        try:
            pkt = us.recv(65535)
        except socket.timeout:
            if proc.poll() is not None:
                print('ffmpeg ended', flush=True)
                return
            continue
        if drop_rate and random.random() < drop_rate:
            continue
        res = rtp.feed(pkt)
        try:
            if res:
                slices, key = res
                if not config:
                    sps, pps = rtp.sps, rtp.pps
                    if not (sps and pps):
                        sps, pps = sps_pps_from_sdp(sdp_path)
                    if not (sps and pps) or not key:
                        continue                       # wait for a key frame and the parameter sets
                    s.sendall(packet(1, 0, avcc_record(sps, pps), seq, 0)); seq += 1
                    config = True
                    print('config sent', flush=True)
                t_a = time.perf_counter()
                if last_at:
                    gap = (t_a - last_at) * 1000.0
                    gap_max = max(gap_max, gap)
                    if gap > 50: gap_late += 1
                last_at = t_a
                payload = b''.join(b'\x00\x00\x00\x01' + n for n in slices)
                s.sendall(packet(2, 1 if key else 0, payload, seq, int(frames * 1000000 / FPS)))
                send_max = max(send_max, (time.perf_counter() - t_a) * 1000.0)
                seq += 1; frames += 1
            now = time.time()
            if now - last_hb >= 1.0:
                s.sendall(packet(5, 0, b'', seq, int(now * 1000000))); seq += 1
                last_hb = now
                print('frames=%d rate=%.1f fps  frame-gap max=%dms late(>50ms)=%d  send max=%dms  dropped=%d'
                      % (frames, frames / (now - t0), gap_max, gap_late, send_max, rtp.dropped), flush=True)
                gap_max = 0.0; gap_late = 0; send_max = 0.0
        except OSError as e:
            print('disconnected:', e, '- reconnecting', flush=True)
            try: s.close()
            except OSError: pass
            s = connect()
            drain(us)
            rtp = RtpFrames()                          # fresh state: wait for a new key frame
            config = False; seq = 0

if __name__ == '__main__':
    main()
