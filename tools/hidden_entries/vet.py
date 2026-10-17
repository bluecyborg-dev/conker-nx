"""vet.py XBE FUNCTIONS_JSON MISSED_TXT : show the instruction before and the first instructions at each candidate."""
import json, struct, sys, re
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
d = open(sys.argv[1], 'rb').read()
base, = struct.unpack_from('<I', d, 0x104); nsec, shdr = struct.unpack_from('<II', d, 0x11C); shdr -= base
secs = [struct.unpack_from('<IIIII', d, shdr + i * 56) for i in range(nsec)]
def raw(a, n):
    for fl, va, vs, ra, rs in secs:
        if va <= a and a + n <= va + rs: return d[ra + a - va: ra + a - va + n]
fns = sorted(json.load(open(sys.argv[2])), key=lambda f: int(f['start'], 16))
md = Cs(CS_ARCH_X86, CS_MODE_32)
seen = set()
for line in open(sys.argv[3]):
    m = re.match(r'0x([0-9A-F]+) inside (\S+)( after 0x([0-9A-F]+))?, referenced from 0x([0-9A-F]+)', line)
    if not m: continue
    v = int(m.group(1), 16); ref = int(m.group(5), 16)
    if v in seen: continue
    seen.add(v)
    # the function that contains or precedes v
    f = max((x for x in fns if int(x['start'], 16) < v), key=lambda x: int(x['start'], 16))
    lo, hi = int(f['start'], 16), int(f['end'], 16)
    same_fn = lo <= ref < max(hi, v + 1)
    prev = None
    for ins in md.disasm(raw(lo, v - lo) or b'', lo):
        prev = ins
    prevtxt = '%s %s' % (prev.mnemonic, prev.op_str) if prev and prev.address + prev.size == v else 'MISALIGNED'
    first = ['%s %s' % (i.mnemonic, i.op_str) for i in list(md.disasm(raw(v, 24) or b'', v))[:3]]
    ok = (not same_fn) and (prevtxt.split()[0] in ('ret', 'jmp', 'int3', 'nop') if prevtxt != 'MISALIGNED' else False)
    print('%s 0x%08X ref 0x%08X%s | prev: %-28s | %s' % ('OK ' if ok else '-- ', v, ref, ' (same fn)' if same_fn else '', prevtxt[:28], ' ; '.join(first)))
