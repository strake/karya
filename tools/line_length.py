#!/usr/bin/python
# Copyright 2017 Evan Laforge
# This program is distributed under the terms of the GNU General Public
# License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

# Make a line length histogram.
from __future__ import print_function
import sys

ignore = set(['Solkattu/All.hs'])

skip_comments = False

def main():
    line_comments = 0
    block_comments = 0
    blanks = 0
    comment_level = 0
    lengths = {}
    for fname in sys.argv[1:]:
        if fname in ignore:
            continue
        lines = open(fname).readlines()
        for lineno, line in enumerate(lines):
            line = line.decode('utf-8')
            if line.strip().startswith('--'):
                line_comments += 1
                if skip_comments:
                    continue
            comment_level = max(
                0, comment_level + line.count('{-') - line.count('-}'))
            if comment_level > 0:
                block_comments += 1
                if skip_comments:
                    continue
            if not line.strip():
                blanks += 1
            else:
                cols = len(line) - 1
                lengths[cols] = lengths.get(cols, 0) + 1
                if cols > 80:
                    print('%s:%d' % (fname, lineno))
                    print(line[:120])

    print('blank lines:', blanks)
    print('comments: line:', line_comments, 'block:', block_comments,
        'total:', line_comments + block_comments)
    for length, count in sorted(lengths.items()):
        print('%4d %d' % (length, count))

if __name__ == '__main__':
    main()
