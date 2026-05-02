#!/usr/bin/env python3
"""Resize a ClassicWorld (.cw) file to 256x64x256.

The original blocks are centered in the larger map. Outside the centered
region, the world is a superflat: bedrock from y=0..31 and air above. The
Spawn compound's X/Z are shifted by the centering offset so the player
still lands inside the original map.

Usage:
    cw_resize.py <input.cw> [output.cw]

Default output is <input>_256.cw next to the input.
"""

import gzip
import struct
import sys
from io import BytesIO
from pathlib import Path

# --- NBT codec (just enough to round-trip ClassicWorld) ---

TAG_END = 0
TAG_BYTE = 1
TAG_SHORT = 2
TAG_INT = 3
TAG_LONG = 4
TAG_FLOAT = 5
TAG_DOUBLE = 6
TAG_BYTE_ARRAY = 7
TAG_STRING = 8
TAG_LIST = 9
TAG_COMPOUND = 10


def read_string(b):
    n = struct.unpack(">H", b.read(2))[0]
    return b.read(n).decode("utf-8")


def write_string(b, s):
    enc = s.encode("utf-8")
    b.write(struct.pack(">H", len(enc)))
    b.write(enc)


def read_payload(b, tag):
    if tag == TAG_BYTE:
        return struct.unpack(">b", b.read(1))[0]
    if tag == TAG_SHORT:
        return struct.unpack(">h", b.read(2))[0]
    if tag == TAG_INT:
        return struct.unpack(">i", b.read(4))[0]
    if tag == TAG_LONG:
        return struct.unpack(">q", b.read(8))[0]
    if tag == TAG_FLOAT:
        return struct.unpack(">f", b.read(4))[0]
    if tag == TAG_DOUBLE:
        return struct.unpack(">d", b.read(8))[0]
    if tag == TAG_BYTE_ARRAY:
        n = struct.unpack(">i", b.read(4))[0]
        return b.read(n)
    if tag == TAG_STRING:
        return read_string(b)
    if tag == TAG_LIST:
        elem = b.read(1)[0]
        n = struct.unpack(">i", b.read(4))[0]
        return ("list", elem, [read_payload(b, elem) for _ in range(n)])
    if tag == TAG_COMPOUND:
        kids = []
        while True:
            t = b.read(1)
            if not t or t[0] == TAG_END:
                break
            t = t[0]
            name = read_string(b)
            kids.append((t, name, read_payload(b, t)))
        return kids
    raise ValueError(f"unknown tag {tag}")


def write_payload(b, tag, val):
    if tag == TAG_BYTE:
        b.write(struct.pack(">b", val))
    elif tag == TAG_SHORT:
        b.write(struct.pack(">h", val))
    elif tag == TAG_INT:
        b.write(struct.pack(">i", val))
    elif tag == TAG_LONG:
        b.write(struct.pack(">q", val))
    elif tag == TAG_FLOAT:
        b.write(struct.pack(">f", val))
    elif tag == TAG_DOUBLE:
        b.write(struct.pack(">d", val))
    elif tag == TAG_BYTE_ARRAY:
        b.write(struct.pack(">i", len(val)))
        b.write(val)
    elif tag == TAG_STRING:
        write_string(b, val)
    elif tag == TAG_LIST:
        _, elem, items = val
        b.write(bytes([elem]))
        b.write(struct.pack(">i", len(items)))
        for item in items:
            write_payload(b, elem, item)
    elif tag == TAG_COMPOUND:
        for ct, cname, cval in val:
            b.write(bytes([ct]))
            write_string(b, cname)
            write_payload(b, ct, cval)
        b.write(bytes([TAG_END]))
    else:
        raise ValueError(f"unknown tag {tag}")


# --- Resize ---

NX, NY, NZ = 256, 64, 256
BEDROCK = 7
AIR = 0
GROUND_HEIGHT = 32  # bedrock fill from y=0..GROUND_HEIGHT-1 outside the centered region


def find(children, name):
    for c in children:
        if c[1] == name:
            return c
    return None


def replace(children, name, new_val):
    out = []
    for c in children:
        if c[1] == name:
            out.append((c[0], c[1], new_val))
        else:
            out.append(c)
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    in_path = Path(sys.argv[1])
    out_path = (
        Path(sys.argv[2])
        if len(sys.argv) > 2
        else in_path.with_name(in_path.stem + "_256.cw")
    )

    with open(in_path, "rb") as f:
        raw = gzip.decompress(f.read())

    src = BytesIO(raw)
    root_tag = src.read(1)[0]
    if root_tag != TAG_COMPOUND:
        raise SystemExit(f"not a ClassicWorld file (root tag {root_tag})")
    root_name = read_string(src)
    root = read_payload(src, TAG_COMPOUND)

    ox = find(root, "X")[2]
    oy = find(root, "Y")[2]
    oz = find(root, "Z")[2]
    blocks = find(root, "BlockArray")[2]
    if len(blocks) != ox * oy * oz:
        raise SystemExit(
            f"BlockArray length {len(blocks)} != X*Y*Z {ox}*{oy}*{oz}"
        )
    print(f"input:  {ox}x{oy}x{oz}, blocks={len(blocks)}")

    if oy != NY:
        raise SystemExit(
            f"input Y dimension {oy} != target {NY}; this script only "
            "centers in X/Z, not in Y"
        )
    if ox > NX or oz > NZ:
        raise SystemExit(f"input larger than {NX}x{NY}x{NZ}; cannot center")

    ox_off = (NX - ox) // 2
    oz_off = (NZ - oz) // 2
    print(f"center offset: x+={ox_off} z+={oz_off}")

    # Build target buffer in YZX order: index = (y*NZ + z)*NX + x
    new = bytearray(NX * NY * NZ)
    # Superflat fill: bottom GROUND_HEIGHT layers are bedrock, rest air.
    layer_size = NZ * NX
    bedrock_layer = bytes([BEDROCK]) * layer_size
    for y in range(GROUND_HEIGHT):
        new[y * layer_size : (y + 1) * layer_size] = bedrock_layer

    # Overlay original map into the centered region, row by row.
    for y in range(oy):
        for z in range(oz):
            old_off = (y * oz + z) * ox
            new_off = (y * NZ + (z + oz_off)) * NX + ox_off
            new[new_off : new_off + ox] = blocks[old_off : old_off + ox]

    # Patch dimensions and BlockArray.
    root = replace(root, "X", NX)
    root = replace(root, "Y", NY)
    root = replace(root, "Z", NZ)
    root = replace(root, "BlockArray", bytes(new))

    # Shift Spawn (block coords) to follow the centering.
    spawn_entry = find(root, "Spawn")
    if spawn_entry is not None:
        st, sn, spawn_kids = spawn_entry
        new_spawn = []
        for sc in spawn_kids:
            ct, cn, cv = sc
            if cn == "X":
                new_spawn.append((ct, cn, cv + ox_off))
            elif cn == "Z":
                new_spawn.append((ct, cn, cv + oz_off))
            else:
                new_spawn.append(sc)
        root = replace(root, "Spawn", new_spawn)

    out = BytesIO()
    out.write(bytes([TAG_COMPOUND]))
    write_string(out, root_name)
    write_payload(out, TAG_COMPOUND, root)

    compressed = gzip.compress(out.getvalue())
    with open(out_path, "wb") as f:
        f.write(compressed)
    print(
        f"output: {NX}x{NY}x{NZ}, blocks={NX * NY * NZ}, "
        f"file={len(compressed)} bytes -> {out_path}"
    )


if __name__ == "__main__":
    main()
