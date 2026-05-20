#!/bin/bash
# Patch Ruby 3.1 uncommon.mk to bypass file2lastrev.rb
# Root cause: Ruby 3.1 moved optparse/fileutils to bundled gems,
# but BASERUBY runs with --disable=gems in OpenWrt host build

set -e

RUBY_SRC="${1:-build_dir/hostpkg/ruby-3.1.2}/uncommon.mk"

if [ ! -f "$RUBY_SRC" ]; then
  echo "⏭️ $RUBY_SRC not found, skipping patch"
  exit 0
fi

echo "🔧 Patching Ruby uncommon.mk (bypass file2lastrev.rb)..."

python3 << 'PYEOF'
import re, sys

ruby_src = sys.argv[1] if len(sys.argv) > 1 else "build_dir/hostpkg/ruby-3.1.2/uncommon.mk"
# Use environment variable instead
import os
ruby_src = os.environ.get("RUBY_MK", "build_dir/hostpkg/ruby-3.1.2/uncommon.mk")

with open(ruby_src, 'r') as f:
    lines = f.readlines()

new_lines = []
skip_next = False
for i, line in enumerate(lines):
    # Find the file2lastrev.rb execution line and replace with no-op
    if 'file2lastrev.rb' in line and 'BASERUBY' in line:
        new_lines.append('\t$(Q) echo "" > $@\n')
        continue
    new_lines.append(line)

with open(ruby_src, 'w') as f:
    f.writelines(new_lines)

print("Patched successfully")
PYEOF

echo "✅ Ruby uncommon.mk patched"
