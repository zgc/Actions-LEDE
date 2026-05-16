#!/usr/bin/env python3
"""Patch Ruby 3.1 for OpenWrt host build compatibility.

Root cause: Ruby 3.1 moved optparse/fileutils/erb to bundled gems.
OpenWrt host build uses BASERUBY with --disable=gems, so all bundled
gems fail to load during configure/compile.

Fix: Replace BASERUBY with system Ruby (Docker has ruby 3.0 with full stdlib).
Also bypass file2lastrev.rb VCS tracking (unnecessary in Docker builds).
"""
import os
import sys

ruby_makefile = sys.argv[1].replace('/uncommon.mk', '/Makefile') if '/uncommon.mk' in sys.argv[1] else None
ruby_mk = sys.argv[1] if len(sys.argv) > 1 else None

if not ruby_mk:
    print("Usage: fix-ruby-bundled-gems.py <path/to/uncommon.mk>")
    sys.exit(1)

if not os.path.isfile(ruby_mk):
    print(f"Skipping: {ruby_mk} not found")
    sys.exit(0)

# Fix 1: Patch uncommon.mk - bypass file2lastrev.rb (line 1191)
with open(ruby_mk, 'r') as f:
    lines = f.readlines()

if len(lines) > 1190:
    old = lines[1190]
    if 'file2lastrev.rb' in old:
        lines[1190] = '\t$(Q) echo "" > $@\n'
        with open(ruby_mk, 'w') as f:
            f.writelines(lines)
        print(f"Patched {ruby_mk}: bypassed file2lastrev.rb")

# Fix 2: Replace BASERUBY with system Ruby
if ruby_makefile and os.path.isfile(ruby_makefile):
    with open(ruby_makefile, 'r') as f:
        mk_lines = f.readlines()
    
    new_mk = []
    for line in mk_lines:
        if line.startswith('BASERUBY = '):
            new_mk.append('BASERUBY = /usr/bin/ruby \n')
        else:
            new_mk.append(line)
    
    with open(ruby_makefile, 'w') as f:
        f.writelines(new_mk)
    print(f"Patched {ruby_makefile}: BASERUBY -> /usr/bin/ruby")
