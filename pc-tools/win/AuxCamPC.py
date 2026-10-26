# AuxCamPC.py -- Windows (also runs on Mac) desktop app: capture the OBS Virtual Camera and push it to the phone over USB.
# No iproxy needed: the sender talks to the Apple USB service directly (HOST = "usb").
import json, os, queue, re, runpy, shutil, subprocess, sys, threading, time

APP_NAME = 'AuxCam 电脑端'
CFG_PATH = os.path.join(os.path.expanduser('~'), '.auxcam_pc.json')
FROZEN = bool(getattr(sys, 'frozen', False))
RES_DIR = getattr(sys, '_MEIPASS', os.path.dirname(os.path.abspath(__file__)))
EXE_DIR = os.path.dirname(sys.executable) if FROZEN else os.path.dirname(os.path.abspath(__file__))
IS_WIN = sys.platform == 'win32'
NOWIN = 0x08000000 if IS_WIN else 0     # CREATE_NO_WINDOW: no black console flashing


def find_sender():
    for d in (RES_DIR, EXE_DIR, os.path.join(EXE_DIR, '..')):
        p = os.path.join(d, 'sender_h264.py')
        if os.path.isfile(p):
            return p
    return None


def find_ffmpeg():
    env = os.environ.get('AUX_FFMPEG')
    if env and os.path.isfile(env):
        return env
    names = ('ffmpeg.exe',) if IS_WIN else ('ffmpeg',)
    for d in (EXE_DIR, os.path.join(EXE_DIR, 'ffmpeg'), RES_DIR, os.path.join(RES_DIR, 'ffmpeg')):
        for n in names:
            p = os.path.join(d, n)
            if os.path.isfile(p):
                return p
    return shutil.which('ffmpeg')


def parse_cameras(text):
    """Pull camera names out of ffmpeg's device listing (dshow on Windows, avfoundation on Mac)."""
    cams = []
    in_video = False
    for line in text.splitlines():
        if 'AVFoundation video devices' in line:
            in_video = True
            continue
        if 'AVFoundation audio devices' in line:
            in_video = False
            continue
        m = re.search(r'\]\s*\[(\d+)\]\s*(.+?)\s*$', line)
        if m and in_video:
            cams.append(m.group(2))
            continue
        m = re.search(r'"([^"]+)"\s*\(video\)', line)          # dshow, new style
        if m:
            cams.append(m.group(1))
            continue
        if 'DirectShow video devices' in line:
            in_video = True
            continue
        if 'DirectShow audio devices' in line:
            in_video = False
            continue
        m = re.search(r'"([^"]+)"\s*$', line)                  # dshow, old style
        if m and in_video and 'Alternative name' not in line:
            cams.append(m.group(1))
    seen, out = set(), []
    for c in cams:
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def list_cameras(ff):
    if not ff:
        return []
    args = [ff, '-hide_banner', '-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'] if IS_WIN else \
           [ff, '-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', '']
    try:
        r = subprocess.run(args, capture_output=True, text=True, errors='ignore', timeout=20, creationflags=NOWIN)
        return parse_cameras((r.stderr or '') + (r.stdout or ''))
    except Exception:
        return []


def friendly(line):
    """Turn the sender's technical messages into plain Chinese for the status bar. Returns (state, text) or None."""
    low = line.lower()
    if low.startswith('warn camera size'):
        return 'warn', '⚠ OBS 画布不是 1080×1920，电脑要缩放每一帧，会卡。请把 OBS 设置→视频 的基础分辨率和输出分辨率都改成 1080×1920'
    if low.startswith('no video from ffmpeg'):
        return 'warn', '电脑这边没有画面进来：OBS 虚拟摄像头是否开着？或者电脑编码太慢'
    if low.startswith('connected'):
        return 'ok', '已连上手机'
    if low.startswith('waiting phone'):
        if 'no iphone' in low:
            return 'warn', '没找到手机：请插好 USB 线、解锁手机、点“信任”'
        if 'refused port' in low:
            return 'warn', '手机已连上，但 AuxCam 没打开：请先打开手机上的 AuxCam'
        if '10061' in low or 'refused' in low or 'no such file' in low or 'errno 2' in low:
            return 'bad', '没找到苹果 USB 驱动：请安装 iTunes 或 Apple Devices（微软商店可下），然后重新开始'
        return 'warn', '正在等手机…'
    if low.startswith('disconnected'):
        return 'warn', '手机断开了，正在自动重连…'
    if low.startswith('ffmpeg ended'):
        return 'bad', '摄像头采集中断了（OBS 虚拟摄像头是否还开着？）'
    if low.startswith('config sent'):
        return 'ok', '已连上手机，正在推流'
    return None


STATS_RE = re.compile(r'rate=([\d.]+) fps\s+frame-gap max=(\d+)ms late\(>50ms\)=(\d+).*dropped=(\d+)')


def apple_service_up():
    """Windows: is the Apple USB service (comes with iTunes / Apple Devices) running? Mac/other: assume yes."""
    if not IS_WIN:
        return True
    import socket
    try:
        socket.create_connection(('127.0.0.1', 27015), timeout=2).close()
        return True
    except OSError:
        return False


def open_apple_store():
    try:
        os.startfile('ms-windows-store://search/?query=Apple%20Devices')
    except Exception:
        import webbrowser
        webbrowser.open('https://apps.microsoft.com/search?query=Apple%20Devices')


def sender_args(camera, enc, mbps):
    sender = find_sender()
    if FROZEN:
        base = [sys.executable, '--sender']
    else:
        base = [sys.executable, '-u', sender]
    return base + ['usb', '28765', 'cam:' + camera, 'high', '', '', str(mbps)]


def kill_tree(proc):
    if proc is None or proc.poll() is not None:
        return
    try:
        if IS_WIN:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(proc.pid)], capture_output=True, creationflags=NOWIN)
        else:
            import signal
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def run_sender_mode():
    """Used by the packaged exe: `AuxCamPC.exe --sender ARGS...` runs the bundled sender script in this process."""
    sender = find_sender()
    sys.argv = [sender] + sys.argv[2:]
    runpy.run_path(sender, run_name='__main__')


def main():
    import tkinter as tk
    from tkinter import ttk

    cfg = {'camera': 'OBS Virtual Camera', 'enc': '自动', 'mbps': '25'}
    try:
        cfg.update(json.load(open(CFG_PATH, encoding='utf-8')))
    except Exception:
        pass

    root = tk.Tk()
    root.title(APP_NAME)
    root.geometry('480x600')
    root.resizable(False, False)
    pad = {'padx': 14}

    ttk.Label(root, text='OBS 虚拟摄像头 → 手机', font=('Microsoft YaHei UI', 15, 'bold')).pack(pady=(14, 2), **pad)
    ttk.Label(root, text='电脑上先在 OBS 里点“启动虚拟摄像头”，手机用 USB 线连电脑并打开 AuxCam。',
              wraplength=440, foreground='#555').pack(pady=(0, 10), **pad)

    box = ttk.LabelFrame(root, text='设置')
    box.pack(fill='x', **pad)
    ttk.Label(box, text='摄像头').grid(row=0, column=0, sticky='w', padx=8, pady=6)
    cam_var = tk.StringVar(value=cfg['camera'])
    cam_box = ttk.Combobox(box, textvariable=cam_var, width=32)
    cam_box.grid(row=0, column=1, padx=4)
    ttk.Label(box, text='编码').grid(row=1, column=0, sticky='w', padx=8, pady=6)
    enc_var = tk.StringVar(value=cfg['enc'])
    ttk.Combobox(box, textvariable=enc_var, width=32, state='readonly',
                 values=['自动', 'NVIDIA 显卡', 'Intel 核显', 'AMD 显卡', 'CPU（吃性能）']).grid(row=1, column=1, padx=4)
    ttk.Label(box, text='画质(码率)').grid(row=2, column=0, sticky='w', padx=8, pady=6)
    mbps_var = tk.StringVar(value=str(cfg['mbps']))
    ttk.Combobox(box, textvariable=mbps_var, width=32, state='readonly',
                 values=['10', '15', '20', '25', '30']).grid(row=2, column=1, padx=4)
    ttk.Label(box, text='Mbps，默认 25 就够，不用动', foreground='#777').grid(row=3, column=1, sticky='w', padx=4, pady=(0, 6))

    status_var = tk.StringVar(value='未开始')
    status_lbl = tk.Label(root, textvariable=status_var, font=('Microsoft YaHei UI', 12, 'bold'),
                          wraplength=440, justify='center', fg='#666')
    status_lbl.pack(pady=(14, 2), **pad)
    stats_var = tk.StringVar(value='')
    ttk.Label(root, textvariable=stats_var, foreground='#444').pack(**pad)

    drv_btn = ttk.Button(root, text='一键打开“Apple Devices”下载页（装好后重开本软件）', command=open_apple_store)

    btn = tk.Button(root, text='开始推流', font=('Microsoft YaHei UI', 15, 'bold'), bg='#2fb67c', fg='white',
                    activebackground='#269966', activeforeground='white', relief='flat', height=2)
    btn.pack(fill='x', pady=12, **pad)

    def copy_log():
        root.clipboard_clear()
        root.clipboard_append(log.get('1.0', 'end'))
        set_status('ok', '日志已复制，直接粘贴发给开发者')

    ttk.Button(root, text='复制日志（出问题时点这个，再发给开发者）', command=copy_log).pack(pady=(0, 6), **pad)

    log = tk.Text(root, height=9, font=('Consolas', 9), bg='#f6f6f6', relief='flat', state='disabled')
    log.pack(fill='both', expand=True, pady=(0, 12), **pad)

    q = queue.Queue()
    st = {'proc': None, 'running': False, 'restarts': 0, 'ff': None, 'last_ok': 0.0}
    COLORS = {'ok': '#1a9a5a', 'warn': '#d98a00', 'bad': '#d03a3a', 'idle': '#666'}

    def set_status(kind, text):
        status_var.set(text)
        status_lbl.config(fg=COLORS.get(kind, '#666'))

    def add_log(text):
        log.config(state='normal')
        log.insert('end', text + '\n')
        n = int(log.index('end-1c').split('.')[0])
        if n > 300:
            log.delete('1.0', '60.0')
        log.see('end')
        log.config(state='disabled')

    def refresh_cams():
        st['ff'] = find_ffmpeg()
        if not st['ff']:
            set_status('bad', '没找到 ffmpeg：请把 ffmpeg.exe 放在本程序同一个文件夹')
            return
        cams = list_cameras(st['ff'])
        cam_box['values'] = cams
        if cams and cam_var.get() not in cams:
            pick = [c for c in cams if 'obs' in c.lower()]
            cam_var.set(pick[0] if pick else cams[0])
        if not cams:
            add_log('没列出任何摄像头：请确认 OBS 已点“启动虚拟摄像头”，再点开始（也可以手动输入摄像头名字）。')

    ttk.Button(box, text='刷新', width=5, command=refresh_cams).grid(row=0, column=2, padx=(2, 8))

    def reader(proc):
        for raw in iter(proc.stdout.readline, ''):
            q.put(('line', raw.rstrip()))
        q.put(('exit', proc.wait()))

    def start():
        if not find_sender():
            set_status('bad', '程序文件不完整：找不到 sender_h264.py')
            return
        ff = find_ffmpeg()
        if not ff:
            set_status('bad', '没找到 ffmpeg：请把 ffmpeg.exe 放在本程序同一个文件夹')
            return
        cam = cam_var.get().strip()
        if not cam:
            set_status('bad', '请先选择摄像头（OBS Virtual Camera）')
            return
        env = dict(os.environ, AUX_FFMPEG=ff, PYTHONIOENCODING='utf-8', PYTHONUNBUFFERED='1')
        enc = {'自动': 'auto', 'NVIDIA 显卡': 'nvenc', 'Intel 核显': 'qsv', 'AMD 显卡': 'amf', 'CPU（吃性能）': 'x264'}.get(enc_var.get(), 'auto')
        env['AUX_ENC'] = enc
        try:
            json.dump({'camera': cam, 'enc': enc_var.get(), 'mbps': mbps_var.get()}, open(CFG_PATH, 'w', encoding='utf-8'))
        except Exception:
            pass
        args = sender_args(cam, enc, int(mbps_var.get() or 25))
        add_log('启动：摄像头=%s 编码=%s 码率=%sM' % (cam, enc_var.get(), mbps_var.get()))
        try:
            proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                    errors='replace', env=env, creationflags=NOWIN,
                                    start_new_session=not IS_WIN)
        except Exception as e:
            set_status('bad', '启动失败：%s' % e)
            return
        st['proc'], st['running'] = proc, True
        threading.Thread(target=reader, args=(proc,), daemon=True).start()
        btn.config(text='停止推流', bg='#d9534f', activebackground='#b94441')
        set_status('warn', '正在启动…')

    def stop(user=True):
        st['running'] = False if user else st['running']
        kill_tree(st['proc'])
        st['proc'] = None
        if user:
            btn.config(text='开始推流', bg='#2fb67c', activebackground='#269966')
            set_status('idle', '已停止')
            stats_var.set('')

    def toggle():
        if st['running']:
            stop(True)
        else:
            st['restarts'] = 0
            start()

    btn.config(command=toggle)

    def poll():
        try:
            while True:
                kind, val = q.get_nowait()
                if kind == 'line':
                    if not val:
                        continue
                    m = STATS_RE.search(val)
                    if m:
                        fps, gap, late, drop = float(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
                        stats_var.set('帧率 %.0f 帧/秒   最大间隔 %d 毫秒   卡顿 %d 次   丢帧 %d' % (fps, gap, late, drop))
                        st['last_ok'] = time.time()
                        st['n'] = st.get('n', 0) + 1
                        if st['n'] % 5 == 1:
                            add_log(val)
                        if fps >= 25:
                            set_status('ok', '推流中（正常）')
                        else:
                            set_status('warn', '推流中，但帧率偏低')
                        continue
                    add_log(val)
                    f = friendly(val)
                    if f:
                        set_status(*f)
                        if f[0] == 'bad' and '苹果 USB 驱动' in f[1]:
                            drv_btn.pack(before=btn, pady=(0, 6), **pad)
                elif kind == 'exit':
                    if st['running']:
                        add_log('推流程序退出（代码 %s）' % val)
                        if st['restarts'] < 5:
                            st['restarts'] += 1
                            set_status('warn', '推流中断，正在自动重试（%d/5）…' % st['restarts'])
                            root.after(2000, lambda: start() if st['running'] else None)
                        else:
                            st['running'] = False
                            btn.config(text='开始推流', bg='#2fb67c', activebackground='#269966')
                            set_status('bad', '连续失败，已停止。请看下面的日志，把日志发给开发者。')
        except queue.Empty:
            pass
        root.after(200, poll)

    def on_close():
        stop(True)
        root.destroy()

    root.protocol('WM_DELETE_WINDOW', on_close)
    refresh_cams()
    if not apple_service_up():
        set_status('bad', '没找到苹果 USB 驱动：请安装 Apple Devices（点下面按钮），装好后重开本软件')
        drv_btn.pack(before=btn, pady=(0, 6), **pad)
    poll()
    root.mainloop()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--sender':
        run_sender_mode()
    else:
        main()
