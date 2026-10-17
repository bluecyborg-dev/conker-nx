"""Ordered conditions after an 8/16-bit sub rebuild the operand at its width.

Conker's decompressor (sub_0054AAD0) does `sub ch, cl; jl refill`. The lifter
rebuilt ch as the 32-bit sum result + cl, unmasked and unsigned, so ch=1,
cl=15 compared 257 < 15 (false) where x86 compares 1 < 15 (true).
"""
from tools.recomp.test_cmov_parity import translate


def _cond_line(code, jcc):
    return next(l for l in code.splitlines() if f'/* {jcc}' in l)


def test_sub_byte_jl_is_signed_at_8_bits():
    # sub ch, cl; jl +1; nop; ret
    code = translate(bytes.fromhex('2ae9' '7c01' '90' 'c3'))
    line = _cond_line(code, 'jl')
    assert '(int8_t)' in line and '0xFFu' in line, line


def test_sub_byte_jb_is_masked():
    # sub al, bl; jb +1; nop; ret
    code = translate(bytes.fromhex('2ac3' '7201' '90' 'c3'))
    line = _cond_line(code, 'jb')
    assert '0xFFu' in line or '_cf' in line, line


def test_sub_dword_jl_unchanged():
    # sub eax, ebx; jl +1; nop; ret
    code = translate(bytes.fromhex('2bc3' '7c01' '90' 'c3'))
    line = _cond_line(code, 'jl')
    assert '(int8_t)' not in line and '(int16_t)' not in line, line
