#!/usr/bin/env python3
"""PLAYBOOK 5.1: DXMT embeds four blobs that Apple's `metal`/`metallib` produce (not available on
Linux): dxmt_command (a .metallib) and air_msad / air_samplepos / air_tessellation (LLVM bitcode
wrappers). build/dxmt-ios/build.sh expects them as `xxd -i` headers in build/dxmt-ios/shader-headers/.
The official release has the compiled bytes linked into Madeira.debug.dylib; carve them from there.

usage: extract_metal_headers.py OFFICIAL_Madeira.app OUT_DIR
Only valid when the shaders are unchanged since the release (dxmt_command.metal, air_*.metal).
If you edit them, compile with Apple's tools instead (PLAYBOOK section 7).
"""
import os, re, struct, sys


def xxd_i(name, data):
    lines = [f"unsigned char {name}[] = {{"]
    for i in range(0, len(data), 12):
        lines.append("  " + ", ".join(f"0x{b:02x}" for b in data[i:i + 12]) + ("," if i + 12 < len(data) else ""))
    lines += ["};", f"unsigned int {name}_len = {len(data)};", ""]
    return "\n".join(lines)


def main():
    app, out = sys.argv[1], sys.argv[2]
    d = open(os.path.join(app, "Madeira.debug.dylib"), "rb").read()
    os.makedirs(out, exist_ok=True)
    # 1. the metallib: 'MTLB' header whose size field (@0x10) is the whole file length
    ref = open(os.path.join(app, "default.metallib"), "rb").read()
    assert struct.unpack_from("<Q", ref, 0x10)[0] == len(ref), "metallib header layout changed"
    hits = []
    i = 0
    while (i := d.find(b"MTLB", i)) >= 0:
        size = struct.unpack_from("<Q", d, i + 0x10)[0]
        if 0 < size < len(d) - i:
            hits.append((i, size))
        i += 4
    if len(hits) != 1:
        sys.exit(f"expected exactly one embedded metallib, found {hits}")
    a, s = hits[0]
    open(os.path.join(out, "dxmt_command.metallib"), "wb").write(d[a:a + s])
    open(os.path.join(out, "dxmt_command.h"), "w").write(xxd_i("dxmt_command", d[a:a + s]))
    print(f"dxmt_command: {s} bytes @ {a:#x}")
    # 2. AIR bitcode wrappers (magic 0x0B17C0DE), identified by the shader they contain
    magic = struct.pack("<I", 0x0B17C0DE)
    want = {b"air_msad": "air_msad", b"air_samplepos": "air_samplepos", b"dxmt.domain_generate_primitives": "air_tessellation"}
    found = {}
    i = 0
    while (i := d.find(magic, i)) >= 0:
        ver, off, size, cpu = struct.unpack_from("<IIII", d, i + 4)
        if off == 20 and 0 < size < 2_000_000 and i + off + size <= len(d):
            blob = d[i:i + off + size]
            for key, nm in want.items():
                if key in blob and nm not in found:
                    found[nm] = blob
        i += 4
    missing = set(want.values()) - set(found)
    if missing:
        sys.exit(f"AIR blobs not found: {missing}")
    for nm, blob in found.items():
        open(os.path.join(out, nm + ".air"), "wb").write(blob)
        open(os.path.join(out, nm + ".h"), "w").write(xxd_i(nm, blob))
        print(f"{nm}: {len(blob)} bytes")


if __name__ == "__main__":
    main()
