#!/usr/bin/env python3
"""PLAYBOOK 5.6: compare a built IPA with the official release IPA of the same version.
usage: parity.py OURS.ipa OFFICIAL.ipa   (needs ldid and llvm-otool on PATH; see env.sh)
Differences that are expected: Xcode's Debug 'stub + .debug.dylib' layout, _CodeSignature,
embedded provisioning, bytes of every compiled binary."""
import plistlib, subprocess, sys, tempfile, zipfile, os, re, collections


def listing(z):
    return {i.filename: i.file_size for i in z.infolist() if not i.is_dir()}


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout


def main():
    ours, off = sys.argv[1], sys.argv[2]
    zo, zf = zipfile.ZipFile(ours), zipfile.ZipFile(off)
    lo, lf = listing(zo), listing(zf)
    only_o = sorted(set(lo) - set(lf))
    only_f = sorted(set(lf) - set(lo))
    common = sorted(set(lo) & set(lf))
    diff_size = [f for f in common if lo[f] != lf[f]]
    print(f"files: ours {len(lo)}, official {len(lf)}, common {len(common)}")

    def group(names):
        g = collections.Counter(re.sub(r"^Payload/Madeira.app/", "", n).split("/")[0] for n in names)
        return ", ".join(f"{k}({v})" for k, v in sorted(g.items()))
    print("only in ours    :", group(only_o) or "-")
    for n in only_o[:8]:
        print("   ", n)
    print("only in official:", group(only_f) or "-")
    for n in only_f[:12]:
        print("   ", n)
    print(f"same name, different size: {len(diff_size)} (first 12)")
    for n in diff_size[:12]:
        print(f"    {n}: ours {lo[n]}, official {lf[n]}")

    app = "Payload/Madeira.app/"
    po = plistlib.loads(zo.read(app + "Info.plist"))
    pf = plistlib.loads(zf.read(app + "Info.plist"))
    print("\nInfo.plist:")
    for k in sorted(set(po) | set(pf)):
        if po.get(k) != pf.get(k):
            print(f"  {k}: ours={po.get(k)!r} official={pf.get(k)!r}")
    if po == pf:
        print("  identical")

    with tempfile.TemporaryDirectory() as t, tempfile.TemporaryDirectory() as t2:
        zo.extract(app + "Madeira", t)
        zf.extract(app + "Madeira.debug.dylib", t2)
        zf.extract(app + "Madeira", t2)
        mo = os.path.join(t, app + "Madeira")
        md = os.path.join(t2, app + "Madeira.debug.dylib")
        print("\nentitlements (ldid -e):")
        eo = sh("ldid", "-e", mo).strip()
        ef = sh("ldid", "-e", os.path.join(t2, app + "Madeira")).strip()  # official stub carries them
        print("  ours:    ", re.sub(r"\s+", " ", eo)[:300])
        print("  official:", re.sub(r"\s+", " ", ef)[:300])

        def libs(p):
            out = sh("llvm-otool", "-L", p).splitlines()[1:]
            return {re.sub(r"\s*\(.*", "", l).strip() for l in out if l.strip()}
        lo_, lf_ = libs(mo), libs(md)
        print("\nlinked libraries (ours vs official Madeira.debug.dylib):")
        print("  only ours    :", sorted(lo_ - lf_))
        print("  only official:", sorted(lf_ - lo_))


if __name__ == "__main__":
    main()
