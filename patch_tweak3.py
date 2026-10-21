# patch_tweak3.py -- (1) run the reader thread at top priority, (2) log why frames are lost
# usage: python3 patch_tweak3.py path/to/Tweak.xm
import sys
p = sys.argv[1]
raw = open(p, 'rb').read()
crlf = b'\r\n' in raw
s = raw.decode('utf-8').replace('\r\n', '\n')
if 'AUXDIAG' in s:
    print('already patched'); sys.exit(0)
pairs = [
("""    (void)arg;
    uint64_t lastSequence = 0;
    double lastFrameAt = 0;
""",
"""    (void)arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   // AUXDIAG: do not get starved by the camera pipeline
    uint64_t lastSequence = 0;
    double lastFrameAt = 0;
    uint64_t diagSkipped = 0, diagCasFail = 0, diagInvalid = 0;
    double diagCopyMax = 0;
"""),
("""                    AuxSharedFrameSlot *slot = &header->slots[index];
                    uint32_t expected = AUX_SHARED_SLOT_READY;
""",
"""                    AuxSharedFrameSlot *slot = &header->slots[index];
                    uint32_t expected = AUX_SHARED_SLOT_READY;
                    double diagT0 = MonotonicSeconds();
                    if (lastSequence != 0 && sequence > lastSequence + 1) diagSkipped += sequence - lastSequence - 1;
"""),
("""                        __atomic_store_n(&slot->state, AUX_SHARED_SLOT_READY, __ATOMIC_RELEASE);
                        if (valid && pb && __atomic_load_n(&gActive, __ATOMIC_ACQUIRE)) {""",
"""                        __atomic_store_n(&slot->state, AUX_SHARED_SLOT_READY, __ATOMIC_RELEASE);
                        { double d = MonotonicSeconds() - diagT0; if (d > diagCopyMax) diagCopyMax = d; }
                        if (!valid) diagInvalid++;
                        if (valid && pb && __atomic_load_n(&gActive, __ATOMIC_ACQUIRE)) {"""),
("""                                SLog(@"shared frame received #%d %zux%zu", gDecoded, width, height);""",
"""                                SLog(@"shared frame received #%d %zux%zu skipped=%llu casfail=%llu invalid=%llu copyMaxMs=%.1f",
                                     gDecoded, width, height, (unsigned long long)diagSkipped,
                                     (unsigned long long)diagCasFail, (unsigned long long)diagInvalid, diagCopyMax * 1000.0);"""),
("""                    // CAS failed (other camera process is reading this slot): do NOT mark as seen, retry next loop
""",
"""                    // CAS failed (other camera process is reading this slot): do NOT mark as seen, retry next loop
                    else { diagCasFail++; }
"""),
]
for a, b in pairs:
    assert s.count(a) == 1, 'pattern not found: ' + a[:60]
    s = s.replace(a, b)
if '#include <pthread/qos.h>' not in s:
    s = s.replace('#include "AuxScale.h"', '#include <pthread/qos.h>\n#include "AuxScale.h"', 1)
if crlf: s = s.replace('\n', '\r\n')
open(p, 'wb').write(s.encode('utf-8'))
print('patched OK', p)
