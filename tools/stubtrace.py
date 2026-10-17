#!/usr/bin/env python3
"""Make every unresolved-call stub in gen/recomp_stubs_unresolved.c log its
first hit as a "[STUB] 0x........" line.

A direct call to an address the disassembler did not detect as a function is
lifted as a stub that only pops the return address. When such a call really
runs, the work it should have done silently does not happen (Carbon: a queue's
get-next returned garbage; its pad driver never started). The log line names
the address to seed. Idempotent; tools/regen.sh runs it after every lift.

    python3 tools/stubtrace.py gen/recomp_stubs_unresolved.c
"""
import re
import sys

STUB = re.compile(r'^void (sub_([0-9A-F]{8}))\(void\) \{ (g_esp \+= \d+;) /\* (.*?) \*/ \}$')


def main(path):
    lines = open(path).read().splitlines()
    out, n = [], 0
    for line in lines:
        m = STUB.match(line)
        if m:
            name, va, pop, note = m.groups()
            note = note.replace('"', "'")
            line = (f'void {name}(void) {{ static int _hit; if (!_hit++) '
                    f'fprintf(stderr, "[STUB] 0x{va} called but not lifted ({note})\\n"); '
                    f'{pop} }}')
            n += 1
        out.append(line)
    text = "\n".join(out) + "\n"
    if "#include <stdio.h>" not in text:
        text = text.replace('#define RECOMP_GENERATED_CODE', '#include <stdio.h>\n#define RECOMP_GENERATED_CODE', 1)
    open(path, "w").write(text)
    print(f"stubtrace: {n} stubs log their first hit")


if __name__ == "__main__":
    main(sys.argv[1])
