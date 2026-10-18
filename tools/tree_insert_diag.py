#!/usr/bin/env python3
"""Add optional diagnostics to Conker's guest tree insertion fix-up.

Use TREE_INSERT_DIAG=1 with tools/regen.sh, then compile that generated tree
with -DRECOMP_TREE_INSERT_DIAG=1. This is a diagnostic build only; it does not
change the guest algorithm or run in normal builds.
"""
from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one {label} marker, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: tree_insert_diag.py GENERATED_CODE_DIR")
    gen = Path(sys.argv[1])
    matches = [p for p in gen.glob("recomp_*.c")
               if "void sub_000139D0(void)" in p.read_text(errors="replace")]
    if len(matches) != 1:
        raise SystemExit("expected exactly one generated sub_000139D0, found %d" % len(matches))

    path = matches[0]
    source = path.read_text()
    func_start = source.find("void sub_000139D0(void)")
    func_end = source.find("\n/**\n * sub_00013B80", func_start)
    if func_start < 0 or func_end < 0:
        raise SystemExit("could not isolate sub_000139D0 in %s" % path)
    prefix, function, suffix = source[:func_start], source[func_start:func_end], source[func_end:]
    if "RECOMP_TREE_INSERT_DIAG" in function:
        print("tree-insert diagnostics already present in %s" % path)
        return

    if "#include <stdio.h>" not in prefix:
        prefix = replace_once(
            prefix,
            "#define RECOMP_GENERATED_CODE\n",
            "#define RECOMP_GENERATED_CODE\n#include <stdio.h>\n",
            "generated-code include",
        )
    function = replace_once(
        function,
        "    (void)_fa; (void)_fb; (void)_fas; (void)_fbs;\n    ebp = g_seh_ebp; /* fpo_leaf: inherit caller's frame */\n\nloc_000139D0: ;",
        "    (void)_fa; (void)_fb; (void)_fas; (void)_fbs;\n#ifdef RECOMP_TREE_INSERT_DIAG\n"
        "    static uint32_t tree_diag_calls;\n"
        "    static uint32_t tree_diag_total_fixups;\n"
        "    uint32_t tree_diag_steps = 0;\n"
        "    uint32_t tree_diag_inserted = 0;\n"
        "#endif\n"
        "    ebp = g_seh_ebp; /* fpo_leaf: inherit caller's frame */\n\nloc_000139D0: ;",
        "tree diagnostic locals",
    )
    function = replace_once(
        function,
        "    edi = ecx;\n    esi = eax;\n    _fa = (uint32_t)(MEM32(edi + 8))",
        "    edi = ecx;\n    esi = eax;\n#ifdef RECOMP_TREE_INSERT_DIAG\n"
        "    tree_diag_inserted = esi;\n"
        "#endif\n"
        "    _fa = (uint32_t)(MEM32(edi + 8))",
        "tree diagnostic inserted node",
    )
    function = replace_once(
        function,
        "loc_00013AC0: ;\n    ecx = MEM32(eax);\n    ebp = MEM32(ecx + 4);\n    edx = MEM32(ebp);\n",
        "loc_00013AC0: ;\n    ecx = MEM32(eax);\n    ebp = MEM32(ecx + 4);\n    edx = MEM32(ebp);\n"
        "#ifdef RECOMP_TREE_INSERT_DIAG\n"
        "    tree_diag_steps++;\n"
        "    if (tree_diag_steps == 128u || (tree_diag_steps > 128u &&\n"
        "            (tree_diag_steps & (tree_diag_steps - 1u)) == 0u)) {\n"
        "        fprintf(stderr, \"[tree-insert-diag] fixup=%u tree=%08X inserted=%08X current=%08X parent=%08X grandparent=%08X left=%08X\\n\",\n"
        "                tree_diag_steps, edi, tree_diag_inserted, esi, ecx, ebp, edx);\n"
        "        fflush(stderr);\n"
        "    }\n"
        "#endif\n",
        "tree fix-up loop",
    )
    function = replace_once(
        function,
        "loc_00013B5C: ;\n    edx = MEM32(edi + 4);",
        "loc_00013B5C: ;\n#ifdef RECOMP_TREE_INSERT_DIAG\n"
        "    {\n"
        "        uint32_t calls = __atomic_add_fetch(&tree_diag_calls, 1u, __ATOMIC_RELAXED);\n"
        "        uint32_t total = __atomic_add_fetch(&tree_diag_total_fixups, tree_diag_steps, __ATOMIC_RELAXED);\n"
        "        if ((calls & 0x3FFFu) == 0u) {\n"
        "            fprintf(stderr, \"[tree-insert-diag] calls=%u fixups=%u average=%u last=%u\\n\",\n"
        "                    calls, total, total / calls, tree_diag_steps);\n"
        "            fflush(stderr);\n"
        "        }\n"
        "    }\n"
        "#endif\n"
        "    edx = MEM32(edi + 4);",
        "tree diagnostic summary",
    )
    path.write_text(prefix + function + suffix)
    print("added optional tree-insert diagnostics to %s" % path)


if __name__ == "__main__":
    main()
