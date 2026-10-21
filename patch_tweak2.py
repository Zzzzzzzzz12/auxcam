# patch_tweak2.py -- do not throw away a frame just because the writer published a newer one while we were copying
# usage: python3 patch_tweak2.py path/to/Tweak.xm
import sys
p = sys.argv[1]
raw = open(p, 'rb').read()
crlf = b'\r\n' in raw
s = raw.decode('utf-8').replace('\r\n', '\n')
a = "                        BOOL valid = current == index && width > 0 && height > 0 &&"
b = ("                        (void)current;   // slot is protected while READING, a newer activeSlot does not invalidate this copy\n"
     "                        BOOL valid = width > 0 && height > 0 &&")
if b in s:
    print('already patched'); sys.exit(0)
assert s.count(a) == 1, 'pattern not found (file differs from expected)'
s = s.replace(a, b)
if crlf: s = s.replace('\n', '\r\n')
open(p, 'wb').write(s.encode('utf-8'))
print('patched OK', p)
