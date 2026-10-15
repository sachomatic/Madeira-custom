#!/usr/bin/env python3
"""Add or replace files inside a Madeira IPA, and read its version.

    patch_ipa.py version  IPA
    patch_ipa.py patch    IPA -o OUT.ipa  [--put DIR_IN_APP=FILE ...] [--put-dir DIR_IN_APP=LOCALDIR ...]

--put arm64ec-windows=tbs.dll   stores tbs.dll as Payload/Madeira.app/arm64ec-windows/tbs.dll
--put-dir x86_64-vcruntime=DIR  stores every file of DIR in that folder of the app

Every other entry is copied unchanged (name, timestamps, permissions,
compression). New files get the permissions of a file already in that folder.
The IPA's code signature no longer matches afterwards; the sideloader
(SideStore, AltStore, Sideloadly, ...) signs the app again anyway.
"""
import argparse
import hashlib
import os
import plistlib
import sys
import zipfile

APP = "Payload/Madeira.app/"


def app_plist(z):
    return plistlib.loads(z.read(APP + "Info.plist"))


def cmd_version(args):
    with zipfile.ZipFile(args.ipa) as z:
        info = app_plist(z)
    print(info.get("CFBundleShortVersionString", ""))


def cmd_patch(args):
    puts = {}  # archive name -> bytes
    for spec in args.put or []:
        folder, _, path = spec.partition("=")
        puts[APP + folder.strip("/") + "/" + os.path.basename(path)] = path
    for spec in args.put_dir or []:
        folder, _, directory = spec.partition("=")
        for name in sorted(os.listdir(directory)):
            full = os.path.join(directory, name)
            if os.path.isfile(full):
                puts[APP + folder.strip("/") + "/" + name] = full
    if not puts:
        sys.exit("nothing to do: give --put or --put-dir")
    for name, path in puts.items():
        if name.lower().endswith((".dll", ".exe")) and open(path, "rb").read(2) != b"MZ":
            sys.exit(f"{path} is not a Windows binary")

    replaced, added = [], []
    with zipfile.ZipFile(args.ipa) as source:
        if APP + "Info.plist" not in source.namelist():
            sys.exit(f"{args.ipa} is not a Madeira IPA (no {APP}Info.plist)")
        info = source.infolist()
        by_dir = {}
        for i in info:
            if not i.filename.endswith("/"):  # files only: a folder entry has directory permissions
                by_dir.setdefault(i.filename.rsplit("/", 1)[0], i)
        with zipfile.ZipFile(args.output, "w") as target:
            for i in info:
                path = puts.pop(i.filename, None)
                if path is None:
                    target.writestr(i, source.read(i), compress_type=i.compress_type)
                    continue
                with open(path, "rb") as f:
                    data = f.read()
                new = zipfile.ZipInfo(i.filename, i.date_time)
                new.external_attr, new.create_system, new.compress_type = i.external_attr, i.create_system, i.compress_type
                target.writestr(new, data, compress_type=i.compress_type)
                replaced.append((i.filename, hashlib.sha256(source.read(i)).hexdigest(), hashlib.sha256(data).hexdigest()))
            for name, path in sorted(puts.items()):
                sibling = by_dir.get(name.rsplit("/", 1)[0])
                with open(path, "rb") as f:
                    data = f.read()
                new = zipfile.ZipInfo(name, sibling.date_time if sibling else (2026, 1, 1, 0, 0, 0))
                new.external_attr = sibling.external_attr if sibling else (0o100644 << 16)
                new.create_system = sibling.create_system if sibling else 3
                target.writestr(new, data, compress_type=zipfile.ZIP_DEFLATED)
                added.append((name, hashlib.sha256(data).hexdigest()))
    for name, old, new in replaced:
        print(f"replaced {name[len(APP):]}  {old[:12]} -> {new[:12]}")
    for name, new in added:
        print(f"added    {name[len(APP):]}  {new[:12]}")
    print(f"wrote {args.output}  sha256 {hashlib.sha256(open(args.output, 'rb').read()).hexdigest()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("version")
    v.add_argument("ipa")
    v.set_defaults(fn=cmd_version)
    p = sub.add_parser("patch")
    p.add_argument("ipa")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--put", action="append")
    p.add_argument("--put-dir", action="append")
    p.set_defaults(fn=cmd_patch)
    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
