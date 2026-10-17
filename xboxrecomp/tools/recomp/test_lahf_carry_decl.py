"""lahf after inc/dec reads CF from _cf, so the function must declare it.

Found on Conker (sub_00389F5A, data decoded as code): `dec ebx; lahf` lifted to
a read of an undeclared _cf and the chunk failed to compile.
"""
from tools.recomp.test_cmov_parity import translate


def test_lahf_after_dec_declares_cf():
    # dec ebx; lahf; ret
    code = translate(bytes.fromhex('4b' '9f' 'c3'))
    if '_cf' in code.split('/* lahf */')[0].splitlines()[-1]:
        assert 'int _cf' in code, code
