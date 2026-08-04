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


def _cls(a, i):
    ci = a["objects"][i][0]
    return a["classes"][ci][1].rstrip(b"\x00").decode() if ci < len(a["classes"]) else "?"


def _obj_values(a, i):
    _, vi, vc = a["objects"][i]
    return [(vi + n, v) for n, v in enumerate(a["values"][vi:vi + vc])]


def _string_of(a, idx):
    if idx >= len(a["objects"]) or _cls(a, idx) != "NSString":
        return None
    for _, v in _obj_values(a, idx):
        if v[1] == 8:
            return v[2].rstrip(b"\x00").decode("utf-8", "replace")
    return None


def _item_title(a, i):
    for _, v in _obj_values(a, i):
        if v[1] == 10:
            t = _string_of(a, int.from_bytes(v[2], "little"))
            if t:
                return t
    return None                       # separators carry no title


def _drop_value(a, pos):
    """Remove one value, fixing every object index that points past it.

    Objects address values as (start, count) into one flat list, so a
    deletion shifts everything after it.
    """
    del a["values"][pos]
    for j, (c, vi, vc) in enumerate(a["objects"]):
        if vi <= pos < vi + vc:
            a["objects"][j] = (c, vi, vc - 1)
        elif vi > pos:
            a["objects"][j] = (c, vi - 1, vc)


def _in_a_menu(a, target):
    """Is this object still an entry in something that looks like a menu?

    The archive also keeps large index arrays that mention every item;
    being in one of those is not what puts an item on screen.
    """
    for i in range(len(a["objects"])):
        if _cls(a, i) not in ("NSMutableArray", "NSArray"):
            continue
        members = [int.from_bytes(v[2], "little")
                   for _, v in _obj_values(a, i) if v[1] == 10]
        if target not in members:
            continue
        kinds = [_cls(a, m) for m in members if m < len(a["objects"])]
        if kinds.count("NSMenuItem") >= max(1, len(kinds) - 1):
            return True
    return False


def _unlink_once(a, title):
    """Unlink one menu item with this title. Returns True if it did."""
    for i in range(len(a["objects"])):
        if _cls(a, i) != "NSMenuItem" or _item_title(a, i) != title:
            continue
        for j in range(len(a["objects"])):
            if _cls(a, j) not in ("NSMutableArray", "NSArray"):
                continue
            entries = [(pos, int.from_bytes(v[2], "little"))
                       for pos, v in _obj_values(a, j) if v[1] == 10]
            members = [m for _, m in entries]
            if i not in members:
                continue
            kinds = [_cls(a, m) for m in members if m < len(a["objects"])]
            if kinds.count("NSMenuItem") < max(1, len(kinds) - 1):
                continue
            at = members.index(i)
            drop = [entries[at][0]]

            def sep(n):
                return (0 <= n < len(members)
                        and _cls(a, members[n]) == "NSMenuItem"
                        and _item_title(a, members[n]) is None)
            # An item removed from between two separators leaves them
            # adjacent, which draws as a double rule.
            if sep(at - 1) and sep(at + 1):
                drop.append(entries[at + 1][0])
            for pos in sorted(drop, reverse=True):
                _drop_value(a, pos)
            return True
    return False


def remove_menu_item(data, title):
    """Unlink EVERY menu item with this title, from every menu.

    The runtime puts the same commands in two places: the app menu and
    its own status-item menu. "Check for Updates..." appears in both, and
    so did "Preferences" (with different ellipses). Removing one leaves
    the command a click away in the other, which is exactly the mistake
    made twice here.

    Item objects stay in the archive; only the menus' references go.
    """
    a = parse(data)
    removed = 0
    while _unlink_once(a, title):
        removed += 1
        if removed > 8:                      # nothing has eight copies
            return None, "refusing to remove more than 8 copies of %r" % title
    if removed == 0:
        return None, "no menu holds an item titled %r" % title

    out = build(a)
    b = parse(out)                           # must still read back
    for i in range(len(b["objects"])):
        if _cls(b, i) == "NSMenuItem" and _item_title(b, i) == title \
                and _in_a_menu(b, i):
            return None, "%r is still held by a menu" % title
    return out, removed


def main(argv):
    if len(argv) == 4 and argv[2] == "--remove-item":
        path, title = argv[1], argv[3]
        data = open(path, "rb").read()
        if build(parse(data)) != data:
            print("✗ %s does not round-trip; refusing to edit" % path, file=sys.stderr)
            return 1
        out, result = remove_menu_item(data, title)
        if out is None:
            print("✗ %s" % result, file=sys.stderr)
            return 1
        open(path, "wb").write(out)
        print("   removed %d menu item(s) titled %r" % (result, title))
        return 0

    if len(argv) == 4 and argv[2] == "--assert-item":
        # `strings` cannot check this: it emits ASCII runs only, so a title
        # containing a real ellipsis (U+2026) comes out split in two and a
        # grep for it never matches. Parse instead.
        a = parse(open(argv[1], "rb").read())
        for i in range(len(a["objects"])):
            if _cls(a, i) == "NSMenuItem" and _item_title(a, i) == argv[3] \
                    and _in_a_menu(a, i):
                print("   %r is in a menu" % argv[3])
                return 0
        print("✗ no menu holds an item titled %r" % argv[3], file=sys.stderr)
        return 1

    # Anything else must be exactly FILE OLD NEW. Without this, a call like
    #   rename-nib.py MainMenu.nib --remove-item "Preferences…"
    # against a build of this tool that predates --remove-item reads as a
    # rename of the literal string "--remove-item", matches nothing, and
    # exits 0. The build then reports success having done nothing at all,
    # which is exactly what happened.
    if len(argv) != 4 or argv[2].startswith("--"):
        print("usage: rename-nib.py FILE OLD NEW\n"
              "       rename-nib.py FILE --remove-item TITLE", file=sys.stderr)
        return 2
    return _rename_main(argv)


def _rename_main(argv):
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
