"""cmovp/cmovnp after MSVC's float-compare idiom (ucomiss; lahf; test ah, 0x44).

Conker reaches both in game code. Unhandled, they lifted to no-op comments and
the conditional move never happened.
"""
from tools.recomp import config
from tools.recomp.translator import FunctionTranslator

BASE = 0x10000


_CONFIG_GLOBALS = ("_SECTIONS", "SECTIONS", "_configured_from",
                   "TEXT_VA_START", "TEXT_VA_END", "RDATA_VA_START", "RDATA_VA_END",
                   "DATA_VA_START", "DATA_VA_END", "KERNEL_THUNK_ADDR", "ENTRY_POINT")


def translate(image):
    """Lift one function at BASE, leaving tools.recomp.config as it was (a
    layout left installed made test_config's fallback check fail when this
    file ran first)."""
    saved = {k: getattr(config, k) for k in _CONFIG_GLOBALS if hasattr(config, k)}
    try:
        return _translate(image)
    finally:
        for k, v in saved.items():
            setattr(config, k, v)


def _translate(image):
    config._install([config.Section('.text', BASE, len(image), 0, len(image), True)],
                    entry_point=BASE, kernel_thunk_addr=BASE,
                    origin='cmov-parity-test')
    db = {BASE: {'start': hex(BASE), 'end': BASE + len(image),
                 '_addr': BASE, 'size': len(image)}}
    return FunctionTranslator(image, db).translate_function(BASE, db[BASE])


def test_cmovp_after_lahf_test_is_lifted():
    # ucomiss xmm0, xmm1; lahf; test ah, 0x44; mov eax, edx; cmovp eax, ecx; ret
    code = translate(bytes.fromhex('0f2ec1' '9f' 'f6c444' '8bc2' '0f4ac1' 'c3'))
    assert 'cmovp' in code, code
    assert 'unimpl' not in code.lower(), code
    assert 'if (' in code.split('cmovp')[0].splitlines()[-1], code


def test_cmovnp_after_lahf_test_is_lifted():
    # ucomiss xmm1, xmm0; lahf; test ah, 0x44; mov eax, ebx; cmovnp eax, ecx; ret
    code = translate(bytes.fromhex('0f2ec8' '9f' 'f6c444' '8bc3' '0f4bc1' 'c3'))
    assert 'cmovnp' in code, code
    assert 'unimpl' not in code.lower(), code
