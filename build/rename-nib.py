#!/usr/bin/env python3
"""build/rename-nib.py — rename the app in the runtime's compiled nibs.

The runtime ships Interface Builder nibs that hard-code "Hammerspoon" in
the application menu, the Dock-adjacent menu titles and the About/Hide/
Quit items. There is no runtime substitution for these: what is in the
nib is what the user reads.

This used to be a length-preserving `perl -pi -e s/Hammerspoon/.../`,
which constrained the product name to exactly 11 characters and, worse,
also rewrote the *selector* `quitHammerspoon:` into a name no class
implements — which is why Quit did nothing. This parses the archive
instead, so the name can be any length and only display strings move.

Format (NIBArchive, reverse-engineered; the round-trip test in
build/verify-nib-rename.sh is what proves this reading is right):

  header  10s magic "NIBArchive", then 10 uint32 LE:
          unknown1, unknown2,
          objectCount, objectOffset, keyCount, keyOffset,
          valueCount, valueOffset, classNameCount, classNameOffset
  object  varint classIndex, varint valueIndex, varint valueCount
  key     varint length, bytes
  value   varint keyIndex, uint8 type, payload by type
  class   varint length, varint extraCount, extraCount * uint32, bytes

Varints are little-endian 7-bit groups; the high bit marks the LAST byte.
"""
import struct
import sys

MAGIC = b"NIBArchive"
HEADER = struct.Struct("<10s10I")

# Value payload sizes for the fixed-width types. Types not listed here
# carry a varint-prefixed byte string (8) or nothing (9 = nil).
FIXED = {0: 1, 1: 2, 2: 4, 3: 8, 4: 0, 5: 0, 6: 4, 7: 8, 10: 4}


class Reader:
    def __init__(self, data, pos=0):
        self.d, self.p = data, pos

    def varint(self):
        n, shift = 0, 0
        while True:
            b = self.d[self.p]
            self.p += 1
            n |= (b & 0x7F) << shift
            if b & 0x80:
                return n
            shift += 7

    def take(self, n):
        out = self.d[self.p:self.p + n]
        self.p += n
        return out


def varint(n):
    """Encode n. The high bit marks the last byte, so it is set on the
    final group only — including for n == 0, which is a single 0x80."""
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n == 0:
            out.append(b | 0x80)
            return bytes(out)
        out.append(b)


def parse(data):
    if data[:10] != MAGIC:
        raise ValueError("not a NIBArchive")
    (_, u1, u2, n_obj, off_obj, n_key, off_key,
     n_val, off_val, n_cls, off_cls) = HEADER.unpack_from(data, 0)

    r = Reader(data, off_obj)
    objects = [(r.varint(), r.varint(), r.varint()) for _ in range(n_obj)]

    r = Reader(data, off_key)
    keys = []
    for _ in range(n_key):
        keys.append(r.take(r.varint()))

    r = Reader(data, off_val)
    values = []
    for _ in range(n_val):
        k = r.varint()
        t = r.d[r.p]
        r.p += 1
        if t in FIXED:
            payload = r.take(FIXED[t])
        elif t == 8:
            payload = r.take(r.varint())
        elif t == 9:
            payload = b""
        else:
            raise ValueError("unknown value type %d at %d" % (t, r.p))
        values.append([k, t, payload])

    r = Reader(data, off_cls)
    classes = []
    for _ in range(n_cls):
        ln = r.varint()
        extra = r.varint()
        extras = [struct.unpack("<I", r.take(4))[0] for _ in range(extra)]
        classes.append((extras, r.take(ln)))

    return {"u1": u1, "u2": u2, "objects": objects, "keys": keys,
            "values": values, "classes": classes}


def build(a):
    obj = b"".join(varint(c) + varint(v) + varint(n) for c, v, n in a["objects"])
    key = b"".join(varint(len(k)) + k for k in a["keys"])

    val = bytearray()
    for k, t, payload in a["values"]:
        val += varint(k) + bytes([t])
        if t == 8:
            val += varint(len(payload))
        val += payload

    cls = bytearray()
    for extras, name in a["classes"]:
        cls += varint(len(name)) + varint(len(extras))
        for e in extras:
            cls += struct.pack("<I", e)
        cls += name

    off_obj = HEADER.size
    off_key = off_obj + len(obj)
    off_val = off_key + len(key)
    off_cls = off_val + len(val)
    head = HEADER.pack(MAGIC, a["u1"], a["u2"],
                       len(a["objects"]), off_obj,
                       len(a["keys"]), off_key,
                       len(a["values"]), off_val,
                       len(a["classes"]), off_cls)
    return head + obj + key + bytes(val) + bytes(cls)


def is_selector(b):
    """Objective-C selectors and display strings share the same nib key
    (NS.bytes — every NSString is archived the same way), so they can
    only be told apart by shape. `quitHammerspoon:` is a selector the
    runtime implements; renaming it left the Quit menu item wired to a
    method no class has, which is exactly what the old substitution did.

    A selector is an identifier ending in a colon, with no spaces. Every
    display string carrying the app name has a space in it or is the bare
    name, so this separates them cleanly.
    """
    if not b.endswith(b":"):
        return False
    body = b[:-1]
    return bool(body) and b" " not in b and all(
        c in b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:"
        for c in body)


def rename(data, old, new):
    """Rename display strings, never selectors."""
    a = parse(data)
    old_b, new_b = old.encode(), new.encode()
    changed, skipped = [], []
    for v in a["values"]:
        if v[1] != 8 or old_b not in v[2]:
            continue
        if is_selector(v[2]):
            skipped.append(v[2].decode("utf-8", "replace"))
            continue
        before = v[2]
        v[2] = v[2].replace(old_b, new_b)
        changed.append((before.decode("utf-8", "replace"),
                        v[2].decode("utf-8", "replace")))
    return build(a), changed, skipped


def main(argv):
    if len(argv) != 4:
        print("usage: rename-nib.py FILE OLD NEW", file=sys.stderr)
        return 2
    path, old, new = argv[1], argv[2], argv[3]
    data = open(path, "rb").read()

    # Refuse to write anything unless this exact file round-trips. If the
    # parse is wrong the rebuild is wrong, and a corrupt MainMenu.nib is
    # an app that will not start.
    if build(parse(data)) != data:
        print("✗ %s does not round-trip; refusing to edit" % path, file=sys.stderr)
        return 1

    out, changed, skipped = rename(data, old, new)
    if not changed and not skipped:
        return 0
    parse(out)  # must still be readable
    open(path, "wb").write(out)
    for before, after in changed:
        print("   %-32s -> %s" % (before, after))
    for s in skipped:
        print("   %-32s    (selector, left alone)" % s)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
