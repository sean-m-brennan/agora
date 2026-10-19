#!/usr/bin/env python3
"""key_fork_scan.py — look through a cohort run's logs for the group-key fork
shape of AT ISSUES §2.61 (rep-2368077: two settled nodes refused a LOWER key at
their own epoch, so the cohort never converged).

A node may refuse a rotation for many ordinary reasons; every one of them
refuses a key that sorts ABOVE its own, or one that is already its own. What
should never happen is:

  * a refusal of a key that sorts BELOW ours ("ours stands" is then wrong, and
    "a key we already retired" means the cohort's winner is in our retired list);
  * "its key seed did not load" (the update was malformed or mis-decoded).

Also reported, as context: group decrypt failures per node, and the last key
each node's network process installed.

Usage: key_fork_scan.py <run dir> [...]    exit 1 if any run shows the shape.
"""
import os
import re
import sys

ANSI = re.compile(r'\x1b\[[0-9;]*m')
REFUSAL = re.compile(
    r'rotation from (\S+) not adopted \(theirs epoch (\d+), ours (\d+), '
    r'carries_key=([01])\) — (.*?); theirs (\S+?)…, ours (\S+?)…')
INSTALLED = re.compile(r'(\w+): installed group key ([0-9a-f]+)… epoch (\d+)')


def node_logs(run):
    for node in sorted(os.listdir(run)):
        d = os.path.join(run, node)
        if not os.path.isdir(d):
            continue
        for name in ('agorad.log', 'node.log'):
            p = os.path.join(d, name)
            if os.path.isfile(p):
                yield node, p


def scan(run):
    bad, notes = [], []
    for node, path in node_logs(run):
        decrypt_failed, net_key = 0, None
        with open(path, errors='replace') as f:
            for raw in f:
                line = ANSI.sub('', raw)
                if 'group decrypt failed' in line:
                    decrypt_failed += 1
                m = INSTALLED.search(line)
                if m and m.group(1).lower().startswith('net'):
                    net_key = '%s… epoch %s' % (m.group(2), m.group(3))
                m = REFUSAL.search(line)
                if not m:
                    continue
                sender, reason, theirs, ours = (m.group(1), m.group(5),
                                                m.group(6), m.group(7))
                if 'seed did not load' in reason:
                    bad.append('%s: %s' % (node, line.strip()))
                elif theirs != '?' and theirs < ours:
                    bad.append('%s: refused a LOWER key from %s (%s): %s'
                               % (node, sender, reason, line.strip()))
        notes.append('  %-10s group decrypt failures %-4d network key %s'
                     % (node, decrypt_failed, net_key or '(none logged)'))
    return bad, notes


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    found = False
    for run in argv[1:]:
        bad, notes = scan(run)
        verdict = 'FORK SHAPE' if bad else 'clean'
        print('%s: %s' % (run, verdict))
        for b in bad[:20]:
            print('  ' + b)
        if len(bad) > 20:
            print('  … %d more' % (len(bad) - 20))
        print('\n'.join(notes))
        found = found or bool(bad)
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
