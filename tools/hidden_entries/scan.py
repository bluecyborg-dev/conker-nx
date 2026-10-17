"""scan.py XBE FUNCTIONS_JSON > candidates.txt : entries hidden inside known functions or in gaps.

A candidate is an address right after an unconditional ret/jmp inside a known
function that the function's own code never branches to (directly or through a
jump table it indexes), but that something else points at: an aligned dword in
a non-code section, or an immediate/displacement in code.
"""
import json, struct, sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
from capstone.x86 import X86_OP_IMM, X86_OP_MEM
d = open(sys.argv[1], 'rb').read()
base, = struct.unpack_from('<I', d, 0x104); nsec, shdr = struct.unpack_from('<II', d, 0x11C); shdr -= base
secs = []; names = []
for i in range(nsec):
    fl, va, vs, ra, rs, na = struct.unpack_from('<IIIIII', d, shdr + i * 56)
    secs.append((fl, va, vs, ra, rs)); names.append(d[na - base:na - base + 12].split(b'\0')[0].decode(errors='replace'))
DATA = {'.rdata', '.data', '.data1', 'XON_RD'}
def raw(a, n):
    for fl, va, vs, ra, rs in secs:
        if va <= a and a + n <= va + rs: return d[ra + a - va: ra + a - va + n]
def rd32(a):
    b = raw(a, 4); return struct.unpack('<I', b)[0] if b else None
fns = sorted(json.load(open(sys.argv[2])), key=lambda f: int(f['start'], 16))
starts = {int(f['start'], 16) for f in fns}
md = Cs(CS_ARCH_X86, CS_MODE_32); md.detail = True
refs = {}                       # address -> where referenced from
text_ranges = []
for f in fns:
    lo, hi = int(f['start'], 16), int(f['end'], 16)
    text_ranges.append((lo, hi))
# 1. aligned dwords in the data sections (this XBE flags .rdata and .data executable too)
for (fl, va, vs, ra, rs), nm in zip(secs, names):
    if nm not in DATA: continue
    for o in range(0, rs - 3, 4):
        v = struct.unpack_from('<I', d, ra + o)[0]
        refs.setdefault(v, va + o)
cands = []
for f in fns:
    lo, hi = int(f['start'], 16), int(f['end'], 16)
    code = raw(lo, hi - lo)
    if not code: continue
    insns = list(md.disasm(code, lo))
    internal = set()
    after_end = []
    for k, ins in enumerate(insns):
        for op in ins.operands:
            if op.type == X86_OP_IMM:
                v = op.imm & 0xFFFFFFFF
                if ins.group(1) or ins.group(7):      # jump / relative branch
                    internal.add(v)
                else:
                    refs.setdefault(v, ins.address)
            elif op.type == X86_OP_MEM and op.mem.disp:
                v = op.mem.disp & 0xFFFFFFFF
                if ins.mnemonic == 'jmp' and op.mem.scale == 4:   # jump table owned by this function
                    t = v
                    while True:
                        e = rd32(t)
                        if e is None or not (lo <= e < hi): break
                        internal.add(e); t += 4
                elif op.mem.index != 0 or op.mem.base == 0:
                    refs.setdefault(v, ins.address)
        if ins.mnemonic in ('ret', 'jmp') and k + 1 < len(insns):
            after_end.append(insns[k + 1].address)
    for a in after_end:
        if a in internal or a in starts: continue
        # skip padding
        b = raw(a, 1)
        if b in (b'\xcc', b'\x90'): continue
        if a in refs:
            cands.append((a, f['start'], refs[a]))
# 2. referenced addresses in executable sections that no function covers
import bisect
los = [lo for lo, hi in text_ranges]
for fl, va, vs, ra, rs in secs[:1]:            # .text
    for v, r in refs.items():
        if not (va <= v < va + rs) or v in starts: continue
        i = bisect.bisect_right(los, v) - 1
        if i >= 0 and text_ranges[i][0] <= v < text_ranges[i][1]: continue
        b = raw(v, 1)
        if b in (b'\xcc', b'\x90', b'\x00', None): continue
        # must decode as code and be preceded by ret/jmp/int3/padding or a function end
        prev_end = text_ranges[i][1] if i >= 0 else 0
        prev_lo = text_ranges[i][0] if i >= 0 else 0
        if v - prev_end > 64:
            # Further out only straight after padding or after a jump table
            # (a dword pointing back into the previous function): the
            # function before ended with a switch whose table sits in .text.
            b1 = raw(v - 1, 1)
            tail = rd32(v - 4)
            if not (b1 in (b'\xcc', b'\x90')
                    or (tail is not None and prev_lo <= tail < prev_end)):
                continue
        cands.append((v, 'gap after 0x%08X' % prev_end, r))
for a, fs, r in sorted(set(cands)):
    print('0x%08X inside %s, referenced from 0x%08X' % (a, fs, r))
print(len(cands), 'candidates')
