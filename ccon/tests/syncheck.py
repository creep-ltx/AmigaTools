#!/usr/bin/env python3
"""syncheck.py - are the tests' copies of handler procs still verbatim?

Many harnesses here run procs copied VERBATIM out of ccon-handler.e
(cfgtest, edargtest, dplinetest, ...). A copy that drifts tests code the
handler no longer has - silently. This compares every PROC a test file
shares by name with the handler, ignoring `->` comments and blank lines,
and lists the ones that differ. Procs a harness adapts on purpose are
listed in ADAPTED and only reported, not failed.

Run from anywhere: tests/syncheck.py   (exit 1 if any copy drifted)
Written for Audit8 (D1/D2: dplinetest and cfgtest had drifted unseen).
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
HANDLER = os.path.join(HERE, '..', 'ccon-handler.e')

# the harnesses that claim VERBATIM copies - only these are held to it.
# edanchortest, ederasetest, sbresizetest and the like are transcribed
# MODELS of a given release (their headers say which) and are not.
VERBATIM = ['cfgtest.e', 'dplinetest.e', 'edargtest.e', 'hidpentest.e',
            'histdeduptest.e']

# test file -> procs it adapts deliberately (globals swapped in, etc.)
ADAPTED = {
    'edargtest.e': {'edrepeat'},
    'histdeduptest.e': {'historder'},   # the handler's has the hover cache
}

PROC_RE = re.compile(r'^PROC\s+([A-Za-z0-9_]+)\s*\(', re.M)


def procs(text):
    """name -> body text (PROC line to its ENDPROC line), comments stripped"""
    out = {}
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        m = PROC_RE.match(lines[i])
        if m and re.search(r'\)\s+IS\s', lines[i]):
            out[m.group(1)] = norm([lines[i]])    # PROC x(..) IS expr
            i += 1
        elif m:
            name = m.group(1)
            body = []
            j = i
            while j < len(lines):
                body.append(lines[j])
                if lines[j].startswith('ENDPROC'):
                    break
                j += 1
            out[name] = norm(body)
            i = j + 1
        else:
            i += 1
    return out


def norm(body):
    res = []
    for l in body:
        l = re.sub(r'\s*->.*$', '', l).rstrip()
        if l.strip():
            res.append(l)
    return '\n'.join(res)


def main():
    handler = procs(open(HANDLER, encoding='latin-1').read())
    bad = 0
    for f in VERBATIM:
        mine = procs(open(os.path.join(HERE, f), encoding='latin-1').read())
        shared = sorted(n for n in mine if n in handler and n != 'main')
        if not shared:
            continue
        drift = [n for n in shared if mine[n] != handler[n]]
        adapted = ADAPTED.get(f, set())
        real = [n for n in drift if n not in adapted]
        note = ', '.join(drift) if drift else 'all verbatim'
        flag = 'DRIFT' if real else 'ok   '
        print('%s %-20s %2d shared: %s' % (flag, f, len(shared), note))
        bad += len(real)
    print('%d drifted cop%s' % (bad, 'y' if bad == 1 else 'ies'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
