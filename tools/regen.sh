#!/usr/bin/env bash
# Regenerate the lifted C from the XBE: disasm -> func_id -> abi -> recomp.
#
#   tools/regen.sh
#
# Environment:
#   XBOXRECOMP_DIR  toolkit            (default: the vendored xboxrecomp/)
#   CONKER_XBE       default.xbe        (default: <repo>/game/default.xbe)
#   CONKER_GEN_DIR   output directory   (default: <repo>/gen)
#   LIFT_ONLY=1     skip disasm/func_id/abi (enough after editing
#                   recomp_manual.c; seeds need the full run)
#   TRACE_FUNCS     JSON list of addresses whose entries are logged
#                   ([TRACE] lines; a bring-up probe, regenerate without it)
#
# Seeds (config/seed_functions.json) are entry points the static pass cannot
# see -- thread start routines and indirect-call targets found at runtime.
# Grow them with:  python3 -m tools.seed_from_log run.log default.xbe \
#                    --functions tools/disasm/output/functions.json \
#                    --seeds <this repo>/config/seed_functions.json
# and review every addition: a seed inside a function splits it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TK="${XBOXRECOMP_DIR:-$HERE/xboxrecomp}"
XBE="${CONKER_XBE:-$HERE/game/default.xbe}"
GEN="${CONKER_GEN_DIR:-$HERE/gen}"

# The project venv (capstone) when there is one.
PY="${PYTHON:-python3}"
[ -x "$HERE/.venv/bin/python" ] && PY="$HERE/.venv/bin/python"

cd "$TK"
if [ "${LIFT_ONLY:-0}" != "1" ]; then
    # disasm reads the section layout from <xbe stem>_analysis.json beside it.
    ANALYSIS="${XBE%.xbe}_analysis.json"
    [ -f "$ANALYSIS" ] || "$PY" -m tools.xbe_parser "$XBE" --json "$ANALYSIS" --quiet
    "$PY" -m tools.disasm "$XBE" --seed-functions "$HERE/config/seed_functions.json"
    "$PY" -m tools.func_id "$XBE"
    "$PY" -m tools.abi_analysis "$XBE"
fi
mkdir -p "$GEN"
# recomp_types.h is written only when absent, so a stale copy would hide
# register-model changes in the toolkit. Nothing here edits it by hand.
rm -f "$GEN/recomp_types.h"
"$PY" -m tools.recomp "$XBE" --game-name "Conker" --all --split 250 \
    --gen-dir "$GEN" --exclude-manual "$HERE/src/recomp_manual.c" \
    --mmio-sections DSOUND,XPP,D3D,XGRPH \
    ${TRACE_FUNCS:+--trace-functions "$TRACE_FUNCS"}

# Conker's recursive tree walk treats the search helper's no-match result
# (base - 32) as a child pointer. Keep this title-specific workaround in the
# regeneration path because gen/ is ignored and the generated edit itself is
# not tracked. The search base is saved in the caller's unused local before
# sub_00354610 and checked after its ret 8, without dereferencing the parent.
"$PY" - "$GEN" <<'PY'
from pathlib import Path
import sys

gen = Path(sys.argv[1])
matches = [p for p in gen.glob("recomp_*.c")
           if "void sub_00355B40(void)" in p.read_text(errors="replace")]
if len(matches) != 1:
    raise SystemExit("expected exactly one generated sub_00355B40 in %s, found %d"
                     % (gen, len(matches)))

path = matches[0]
source = path.read_text()
old_call = """    edx = esp + 0x88;
    PUSH32(esp, edx);
    PUSH32(esp, eax);
    MEM32(esp + 0x40) = edi;
    PUSH32(esp, 0x00355C85u);"""
new_call = """    edx = esp + 0x88;
    MEM32(esp + 0x3C) = eax;
    PUSH32(esp, edx);
    PUSH32(esp, eax);
    PUSH32(esp, 0x00355C85u);"""
old_guard = """loc_00355C85: ;
    edi = eax;"""
new_guard = """loc_00355C85: ;
    /* Manual Conker fix: sub_00354610 returns its input base - 32 when its
     * search has no match (index -1). Compare with the base saved before the
     * call; do not reread it through the parent pointer, which can itself be
     * invalid in this recursive walk. ret 8 restores the caller's esp. */
    ecx = MEM32(esp + 0x3C);
    ecx = ecx - 0x20;
    _fa = (uint32_t)(eax) & 0xFFFFFFFFu; _fb = (uint32_t)(ecx) & 0xFFFFFFFFu;
    _fas = (int32_t)(int32_t)(_fa); _fbs = (int32_t)(int32_t)(_fb);
    /* No matching child is an exhausted search, not another iteration. */
    if (CMP_EQ(_fa, _fb)) { eax = 0; goto loc_00355C9F; }
    edi = eax;"""

if "Manual Conker fix: sub_00354610" in source:
    if old_call in source or "MEM32(esp + 0x3C) = eax;" not in source:
        raise SystemExit("partial Conker guard patch already present in %s" % path)
    print("Conker recursive-walk guard already present in %s" % path)
else:
    if source.count(old_call) != 1 or source.count(old_guard) != 1:
        raise SystemExit("generated sub_00355B40 layout changed; inspect %s and update regen patch"
                         % path)
    source = source.replace(old_call, new_call, 1).replace(old_guard, new_guard, 1)
    path.write_text(source)
    print("applied Conker recursive-walk guard to %s" % path)
PY

# Optional diagnostics for the profile-2 Windmill stall. Build into a separate
# generated-code directory and define RECOMP_TREE_INSERT_DIAG when compiling;
# normal generated builds keep the guest tree routine unchanged.
if [ "${TREE_INSERT_DIAG:-0}" = "1" ]; then
    "$PY" "$HERE/tools/tree_insert_diag.py" "$GEN"
fi

# Every unresolved-call stub logs its first hit ([STUB] lines name addresses
# to seed). STUB_TRACE=0 leaves them silent.
if [ "${STUB_TRACE:-1}" = "1" ] && [ -f "$GEN/recomp_stubs_unresolved.c" ]; then
    "$PY" -I "$HERE/tools/stubtrace.py" "$GEN/recomp_stubs_unresolved.c"
fi
