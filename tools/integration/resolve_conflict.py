#!/usr/bin/env python3
"""List or resolve git conflict blocks in a file, one block at a time.

Usage:
  resolve_conflict.py list <file>
  resolve_conflict.py pick <file> <block> <ours|theirs|both> [<block> <choice> ...]

`both` keeps ours followed by theirs, which is what most additive conflicts
want. Any block left unpicked keeps its markers, so a partial pass is safe.
"""
import re
import sys
from pathlib import Path

PATTERN = re.compile(
    r'^<<<<<<< (?P<label>[^\n]*)\n(?P<ours>.*?)^=======\n(?P<theirs>.*?)^>>>>>>> (?P<theirs_label>[^\n]*)\n',
    re.S | re.M)


def blocks(text):
    return list(PATTERN.finditer(text))


def show(path):
    text = Path(path).read_text()
    found = blocks(text)
    if not found:
        print('no conflict blocks')
        return
    for index, match in enumerate(found, 1):
        ours = match.group('ours').splitlines()
        theirs = match.group('theirs').splitlines()
        print(f'=== block {index}  ours={len(ours)} lines  theirs={len(theirs)} lines')
        for line in ours[:400]:
            print('  O| ' + line)
        if len(ours) > 400:
            print(f'  O| ... {len(ours) - 400} more lines')
        for line in theirs[:400]:
            print('  T| ' + line)
        if len(theirs) > 400:
            print(f'  T| ... {len(theirs) - 400} more lines')


def pick(path, choices):
    text = Path(path).read_text()
    found = blocks(text)
    for index in sorted(choices, reverse=True):
        match = found[index - 1]
        choice = choices[index]
        if choice == 'ours':
            body = match.group('ours')
        elif choice == 'theirs':
            body = match.group('theirs')
        elif choice == 'both':
            body = match.group('ours') + match.group('theirs')
        else:
            raise SystemExit(f'unknown choice {choice}')
        text = text[:match.start()] + body + text[match.end():]
    Path(path).write_text(text)
    remaining = len(blocks(text))
    print(f'{path}: resolved {len(choices)} block(s), {remaining} remaining')


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    command = sys.argv[1]
    target = sys.argv[2]
    if command == 'list':
        show(target)
    elif command == 'pick':
        rest = sys.argv[3:]
        picks = {}
        for i in range(0, len(rest), 2):
            picks[int(rest[i])] = rest[i + 1]
        pick(target, picks)
    else:
        raise SystemExit(__doc__)
