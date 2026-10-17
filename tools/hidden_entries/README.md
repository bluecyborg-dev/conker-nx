# Hidden function entries

Find functions the static pass missed before a run trips over them (`[ICALL] Failed to resolve`).

    docker run --rm -v "$PWD":/work -w /work conker-dev python3 -I tools/hidden_entries/scan.py \
        game/default.xbe xboxrecomp/tools/disasm/output/functions.json > /tmp/cand.txt
    docker run --rm -v "$PWD":/work -w /work conker-dev python3 -I tools/hidden_entries/vet.py \
        game/default.xbe xboxrecomp/tools/disasm/output/functions.json /tmp/cand.txt

`scan.py` lists addresses that something points at (an aligned dword in `.rdata`/`.data`/`.data1`/`XON_RD`,
or an immediate or displacement in code) and that either sit right after a `ret`/`jmp` inside a known
function without being a branch target of that function, or lie in a gap no function covers. `vet.py`
prints the instruction before and the first instructions at each one and marks `OK` those referenced from
outside their function and preceded by `ret`, `jmp`, `int3` or `nop`. Review the `OK` lines, add them to
`config/seed_functions.json` with a note, and run the full `tools/regen.sh`.

First run (2026-10-17): 32 of 51 accepted, among them vtable methods, D3DX `this`-adjust thunks and SEH
filter/handler blocks; three of them had already crashed or stopped the game at run time.
