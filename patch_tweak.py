# patch_tweak.py -- apply the "retry frame when slot busy + poll every 4 ms" fix to tweak-stream/Tweak.xm
# usage: python3 patch_tweak.py path/to/Tweak.xm
import sys
p = sys.argv[1]
raw = open(p, 'rb').read()
crlf = b'\r\n' in raw
s = raw.decode('utf-8').replace('\r\n', '\n')
a = """                        if (pb) CVPixelBufferRelease(pb);
                    }
                }
                lastSequence = sequence;
            }"""
b = """                        if (pb) CVPixelBufferRelease(pb);
                        lastSequence = sequence;   // consumed: remember it
                    }
                    // CAS failed (other camera process is reading this slot): do NOT mark as seen, retry next loop
                } else {
                    lastSequence = sequence;
                }
            }"""
if b in s:
    print('already patched'); sys.exit(0)
assert s.count(a) == 1, 'pattern 1 not found (file differs from expected)'
assert s.count('usleep(15 * 1000);') == 1, 'pattern 2 not found'
s = s.replace(a, b).replace('usleep(15 * 1000);', 'usleep(4 * 1000);')
if crlf: s = s.replace('\n', '\r\n')
open(p, 'wb').write(s.encode('utf-8'))
print('patched OK', p)
