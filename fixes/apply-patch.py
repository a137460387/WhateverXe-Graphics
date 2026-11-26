#!/usr/bin/env python3
"""Apply the serialized-request fix to adapter.dylib.

Usage: python3 apply-patch.py <input.dylib> <output.dylib>

Patches exactly 3 bytes in __text (all conditional jumps -> unconditional):
  0x13f2: 75 -> eb   gate1: skip size==0xd8 && arg3==0 check
  0x141d: 74 -> eb   AIR-path input extent: skip airlen range check
  0x153d: 74 -> eb   AIR-path output extent: skip converted-bitcode range check

After patching, re-sign ad-hoc:  codesign -f -s - <output.dylib>
"""
import sys

PATCHES = [
    (0x13F2, 0x75, 0xEB),
    (0x141D, 0x74, 0xEB),
    (0x153D, 0x74, 0xEB),
]

def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, 'rb').read())
    for off, expect, new in PATCHES:
        actual = data[off]
        if actual != expect:
            print(f"ERROR: offset 0x{off:x} expected 0x{expect:02x}, got 0x{actual:02x}. "
                  "Wrong binary version?", file=sys.stderr)
            sys.exit(2)
        data[off] = new
    open(dst, 'wb').write(data)
    print(f"Patched {len(PATCHES)} bytes: {src} -> {dst}")
    print("Next: codesign -f -s - " + dst)

if __name__ == '__main__':
    main()