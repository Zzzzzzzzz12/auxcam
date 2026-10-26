# sender_h264.py -- push an H.264 live stream to the phone (VCU1 over USB/iproxy)
# ffmpeg encodes and hands the stream over as RTP packets on localhost, so the end of every frame is known EXACTLY
# (RTP marker bit). Nothing is ever cut in half, and a frame is sent the moment it is complete.
# Portrait 1080x1920, 30 fps, full range, no B-frames, low latency.
# Usage:
#   python3 sender_h264.py                      test pattern
#   python3 sender_h264.py HOST PORT SOURCE     SOURCE = video file, or any ffmpeg input URL
#                                               (e.g. udp://0.0.0.0:5000, srt://..., rtmp://...)
#   python3 sender_h264.py 127.0.0.1 28765 cam:"OBS Virtual Camera"
#                                               capture the OBS Virtual Camera directly (Mac: avfoundation, Windows: dshow)
#   python3 sender_h264.py --list-cameras       list camera names this computer offers
import base64, os, plistlib, random, re, shutil, socket, struct, subprocess, sys, tempfile, time

if len(sys.argv) > 1 and sys.argv[1] == '--list-cameras':
    _ff = os.environ.get('AUX_FFMPEG') or shutil.which('ffmpeg') or 'ffmpeg'
    if sys.platform == 'darwin':
        subprocess.run([_ff, '-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', ''])
    else:
        subprocess.run([_ff, '-hide_banner', '-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'])
    sys.exit(0)

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
# AUX_ENC = x264 (software, heavy CPU) | vt (Mac) | nvenc / qsv / amf (Windows GPU) | auto (default)
# AUX_HWDEC = 1 lets ffmpeg decode the SOURCE video with the Mac hardware as well (video files / big streams)
ENC = os.environ.get('AUX_ENC', 'auto').lower()
HWDEC = os.environ.get('AUX_HWDEC', '0') == '1'

def has_encoder(name):
    try:
        out = subprocess.run([FF, '-hide_banner', '-encoders'], capture_output=True, text=True, timeout=20).stdout
        return name in out
    except Exception:
        return False

def works(name):
    """ffmpeg lists every encoder it was built with, even without the matching GPU. Really try one tiny encode."""
    try:
        r = subprocess.run([FF, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=size=640x360:rate=30',
                            '-frames:v', '3', '-pix_fmt', 'nv12', '-c:v', name, '-f', 'null', '-'],
                           capture_output=True, timeout=30)
        return r.returncode == 0
    except Exception:
        return False

# Windows hardware encoders: nvenc (NVIDIA) | qsv (Intel) | amf (AMD).  auto picks the first one ffmpeg lists.
HW_NAMES = {'vt': 'h264_videotoolbox', 'nvenc': 'h264_nvenc', 'qsv': 'h264_qsv', 'amf': 'h264_amf'}
if ENC == 'auto':
    if sys.platform == 'darwin' and has_encoder('h264_videotoolbox'):
        ENC = 'vt'
    elif sys.platform != 'darwin' and has_encoder('h264_nvenc') and works('h264_nvenc'):
        ENC = 'nvenc'
    elif sys.platform != 'darwin' and has_encoder('h264_qsv') and works('h264_qsv'):
        ENC = 'qsv'
    elif sys.platform != 'darwin' and has_encoder('h264_amf') and works('h264_amf'):
        ENC = 'amf'
    else:
        ENC = 'x264'
_LABEL = {'vt': 'VideoToolbox hardware', 'nvenc': 'NVIDIA NVENC hardware', 'qsv': 'Intel QSV hardware',
          'amf': 'AMD AMF hardware', 'x264': 'x264 software'}
print('encoder: %s%s' % (_LABEL.get(ENC, ENC), ' + hardware decode' if HWDEC else ''), flush=True)

def packet(ftype, flags, payload, seq, ts):
    return b'VCU1' + struct.pack('>BBHIIQ', 1, ftype, flags, len(payload), seq & 0xFFFFFFFF, ts) + payload

def avcc_record(sps, pps):
    rec = bytearray([1]) + sps[1:4] + bytes([0xFF, 0xE1])
    rec += struct.pack('>H', len(sps)) + sps + bytes([1]) + struct.pack('>H', len(pps)) + pps
    return bytes(rec)

def pick_dshow_format(name):
    """Ask the Windows camera which formats/sizes it offers. Returns (pixel_format, 'WxH' or '').
    The OBS Virtual Camera offers YUY2 (= ffmpeg 'yuyv422'); some versions also offer nv12.
    We want the camera to deliver exactly W x H, so no scaling is needed on the PC."""
    try:
        r = subprocess.run([FF, '-hide_banner', '-f', 'dshow', '-list_options', 'true', '-i', 'video=' + name],
                           capture_output=True, text=True, errors='ignore', timeout=20)
        text = (r.stderr or '') + (r.stdout or '')
    except Exception:
        return '', ''
    rows = re.findall(r'(?:pixel_format|vcodec)=(\w+)\s+min s=(\d+)x(\d+) fps=[\d.]+ max s=(\d+)x(\d+)', text)
    rank = ['yuyv422', 'nv12', 'uyvy422']
    best = ('', '')
    for want in rank:
        sizes = [(int(a), int(b), int(c), int(d)) for f, a, b, c, d in rows if f == want]
        if not sizes:
            continue
        size = ''
        for (mnw, mnh, mxw, mxh) in sizes:
            if mnw <= W <= mxw and mnh <= H <= mxh:
                size = '%dx%d' % (W, H)          # camera can deliver our exact size
                break
        if not size:
            size = '%dx%d' % (sizes[0][2], sizes[0][3])
        best = (want, size)
        break
    if not best[0]:
        fmts = re.findall(r'pixel_format=(\w+)', text)
        for want in rank:
            if want in fmts:
                return want, ''
    return best

NOSCALE = False

def start_ffmpeg(port, sdp_path):
    pre = ['-hwaccel', 'videotoolbox' if sys.platform == 'darwin' else 'auto'] if HWDEC else []
    global NOSCALE
    if SRC.startswith('cam:'):
        name = SRC[4:] or 'OBS Virtual Camera'
        if sys.platform == 'darwin':
            # Mac: the OBS Virtual Camera shows up as an ordinary camera. Name or index both work.
            # avfoundation asks the device for yuv420p by default, but Mac cameras only offer nv12/uyvy422/yuyv422/...
            # so ask for nv12 explicitly (override with AUX_CAMFMT=uyvy422 etc. if a device wants something else).
            inputs = ['-f', 'avfoundation', '-pixel_format', os.environ.get('AUX_CAMFMT', 'nv12'),
                      '-framerate', str(FPS), '-i', name + ':none']
        else:
            # dshow: let the device use its own default format; set AUX_CAMFMT=nv12 (or yuyv422) to force one.
            fmt, csize = os.environ.get('AUX_CAMFMT', ''), ''
            if not fmt:
                fmt, csize = pick_dshow_format(name)
            print('camera format: %s size: %s' % (fmt or 'default', csize or 'default'), flush=True)
            if csize and csize != '%dx%d' % (W, H):
                print('WARN camera size %s is not %dx%d: the PC has to scale every frame (slow). Set the OBS canvas to %dx%d.'
                      % (csize, W, H, W, H), flush=True)
            if csize == '%dx%d' % (W, H):
                NOSCALE = True
            inputs = ['-f', 'dshow', '-rtbufsize', '256M'] + (['-pixel_format', fmt] if fmt else []) + \
                     (['-video_size', csize] if csize else []) + ['-framerate', str(FPS), '-i', 'video=' + name]
    elif SRC:
        live = '://' in SRC
        inputs = pre + (['-fflags', '+nobuffer', '-flags', '+low_delay'] if live else ['-re', '-stream_loop', '-1']) + ['-i', SRC]
    else:
        inputs = ['-re', '-f', 'lavfi', '-i', 'testsrc2=size=%dx%d:rate=%d' % (W, H, FPS)]
    size_filter = ('fps=%d' % FPS) if NOSCALE else ('scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,fps=%d' % (W, H, W, H, FPS))
    tags = ['-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709']
    if ENC == 'vt':
        # Hardware encoder: almost no CPU, so the Mac cannot starve and stall the stream.
        # Standard (limited) range is fine: the phone decoder converts to full range by itself.
        video = ['-vf', size_filter + ',format=nv12',
                 '-c:v', 'h264_videotoolbox', '-profile:v', PROFILE if PROFILE in ('baseline', 'main', 'high') else 'high',
                 '-realtime', '1', '-allow_sw', '0', '-g', str(FPS), '-bf', '0',
                 '-b:v', '%dM' % MBPS, '-maxrate', '%dM' % (MBPS * 8 // 7)] + tags
    elif ENC in ('nvenc', 'qsv', 'amf'):
        prof = PROFILE if PROFILE in ('baseline', 'main', 'high') else 'high'
        common = ['-vf', size_filter + ',format=nv12', '-profile:v', prof, '-g', str(FPS), '-bf', '0',
                  '-b:v', '%dM' % MBPS, '-maxrate', '%dM' % (MBPS * 8 // 7), '-bufsize', '%dM' % max(2, MBPS * 2 // 5)]
        if ENC == 'nvenc':
            video = common[:0] + ['-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'll', '-rc', 'cbr', '-zerolatency', '1',
                                  '-forced-idr', '1'] + common + tags
        elif ENC == 'qsv':
            video = ['-c:v', 'h264_qsv', '-preset', 'veryfast', '-look_ahead', '0', '-forced_idr', '1'] + common + tags
        else:
            video = ['-c:v', 'h264_amf', '-usage', 'ultralowlatency', '-quality', 'speed', '-rc', 'cbr',
                     '-header_insertion_mode', 'idr', '-gops_per_idr', '1'] + common + tags
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

# ---- USB tunnel without iproxy: talk to the Apple USB service (usbmuxd) directly. Use HOST = "usb". ----
def _mux_open():
    addr = os.environ.get('USBMUXD_SOCKET_ADDRESS', '')          # same variable libimobiledevice uses: "host:port" or a socket path
    if ':' in addr and not addr.startswith('/'):
        h, _, p = addr.rpartition(':')
        return socket.create_connection((h or '127.0.0.1', int(p)), timeout=5)
    if sys.platform == 'win32':
        return socket.create_connection(('127.0.0.1', 27015), timeout=5)     # Apple Mobile Device Service (iTunes / Apple Devices)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(addr or '/var/run/usbmuxd')
    return s

def _mux_send(s, tag, msg):
    body = plistlib.dumps(msg)
    s.sendall(struct.pack('<IIII', 16 + len(body), 1, 8, tag) + body)

def _mux_recv(s):
    head = b''
    while len(head) < 16:
        c = s.recv(16 - len(head))
        if not c: raise OSError('usbmuxd closed')
        head += c
    length = struct.unpack('<I', head[:4])[0]
    body = b''
    while len(body) < length - 16:
        c = s.recv(length - 16 - len(body))
        if not c: raise OSError('usbmuxd closed')
        body += c
    return plistlib.loads(body)

def usb_connect(port):
    """Open a TCP-like tunnel to `port` on the first USB-connected iPhone/iPad. Raises OSError if none / refused."""
    s = _mux_open()
    base = {'ClientVersionString': 'auxcam', 'ProgName': 'auxcam'}
    _mux_send(s, 1, dict(base, MessageType='ListDevices'))
    devs = [d for d in _mux_recv(s).get('DeviceList', []) if d.get('Properties', {}).get('ConnectionType', 'USB') == 'USB']
    s.close()
    if not devs:
        raise OSError('no iPhone found on USB (plug in, unlock, tap "Trust")')
    dev = devs[0]['DeviceID']
    s = _mux_open()
    _mux_send(s, 2, dict(base, MessageType='Connect', DeviceID=dev, PortNumber=socket.htons(port)))
    r = _mux_recv(s)
    if r.get('Number', 1) != 0:
        s.close()
        raise OSError('phone refused port %d (is AuxCam open?) code=%s' % (port, r.get('Number')))
    return s

def connect():
    while True:
        try:
            s = usb_connect(PORT) if HOST == 'usb' else socket.create_connection((HOST, PORT), timeout=5)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.settimeout(None)
            print('connected %s:%d' % (HOST, PORT), flush=True)
            return s
        except OSError as e:
            print('waiting phone... %s' % (e if isinstance(e, OSError) and not getattr(e, 'winerror', None) else 'code=%s %s' % (getattr(e, 'winerror', None) or e.errno, e if 'phone' in str(e) or 'iPhone' in str(e) else '')), flush=True)
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
    s = connect()                         # phone first: ffmpeg must not start (and overflow its buffers) while nobody listens
    proc = start_ffmpeg(port, sdp_path)
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
    last_seen = t0
    while True:
        try:
            pkt = us.recv(65535)
        except socket.timeout:
            if proc.poll() is not None:
                print('ffmpeg ended', flush=True)
                return
            now = time.time()
            if now - last_hb >= 1.0:               # keep the phone from giving up (it drops silent connections after 5 s)
                try:
                    s.sendall(packet(5, 0, b'', seq, int(now * 1000000))); seq += 1
                    last_hb = now
                except OSError:
                    pass
            if t0 and now - last_seen > 3:
                print('no video from ffmpeg for %d s (camera stalled or encoder too slow)' % (now - last_seen), flush=True)
                last_seen = now
            continue
        last_seen = time.time()
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
            print('disconnected: %s code=%s - reconnecting' % (type(e).__name__, getattr(e, 'winerror', None) or e.errno), flush=True)
            try: s.close()
            except OSError: pass
            s = connect()
            drain(us)
            rtp = RtpFrames()                          # fresh state: wait for a new key frame
            config = False; seq = 0

if __name__ == '__main__':
    main()
