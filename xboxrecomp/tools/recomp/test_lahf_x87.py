"""LAHF after an x87 compare that writes EFLAGS (fcomi/fucomi family).

AH is built from g_fp_cmp (-1 less, 0 equal, 1 greater, 2 unordered), the
same bits UCOMISS gives: ZF (0x40), PF (0x04), CF (0x01), bit 1 always set.
Conker's yaw (0x002B0CB0: fucomip; fstp; lahf; test ah, 0x44; jp) read a
stale AH while lahf lifted to a comment.

    python3 -m pytest tools/recomp/test_lahf_x87.py
"""
import re

import pytest

from tools.recomp.lifter import FPU_EFLAGS_COMPARES, _lahf_value


def _eval_ah(expr, cmp):
    """Evaluate the emitted C expression in Python for one g_fp_cmp value."""
    py = expr.replace("(uint8_t)", "").replace("||", " or ")
    py = re.sub(r"\(\(([^()]*)\) \? (0x[0-9A-Fa-f]+) : 0\)", r"(\2 if (\1) else 0)", py)
    return eval(py, {"g_fp_cmp": cmp})


@pytest.mark.parametrize("setter", FPU_EFLAGS_COMPARES)
def test_every_x87_eflags_compare_gives_ah(setter):
    assert "g_fp_cmp" in _lahf_value(setter, [])


@pytest.mark.parametrize("cmp, ah", [(-1, 0x03), (0, 0x42), (1, 0x02), (2, 0x47)])
def test_ah_bits(cmp, ah):
    assert _eval_ah(_lahf_value("fucomip", []), cmp) == ah
