#!/usr/bin/env python3
"""PLAYBOOK 5.4/5.5: assemble Madeira.app from the ninja outputs, ad-hoc sign with ldid, zip an IPA.

Layers for the resource folders (later wins, nothing is overwritten by the next layer):
  1. the checkout (app/Madeira)                      -- tracked resources
  2. --overlay DIR (the user's tree app/Madeira)     -- PE binaries built on Linux (aarch64/arm64ec/i386, vcruntime)
  3. --official IPA/App, ONLY for files still missing -- things Apple's compilers produce (default.metallib,
     Assets.car, icons) and files the Linux builds cannot make (DXMT PE dlls with Metal shaders, ...).
     Every file taken from layer 3 is listed in the report.

usage: bundle.py --repo ~/madeira-ios --official ~/dl/official/x/Payload/Madeira.app --out Madeira.ipa
"""
import argparse, os, plistlib, re, shutil, subprocess, sys, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pbxproj import Project
from gen_ninja import expand


def subst(v, env):
    if isinstance(v, str):
        return expand(v, env)
    if isinstance(v, list):
        return [subst(x, env) for x in v]
    if isinstance(v, dict):
        return {k: subst(x, env) for k, x in v.items()}
    return v


def copy_tree_layers(name, layers, dst, borrowed):
    """Copy dir `name` from each layer into dst; a file from a later layer is only taken if absent."""
    os.makedirs(dst, exist_ok=True)
    for li, base in enumerate(layers):
        if not base:
            continue
        src = os.path.join(base, name)
        if not os.path.isdir(src):
            continue
        for root, _, files in os.walk(src):
            rel = os.path.relpath(root, src)
            os.makedirs(os.path.join(dst, rel), exist_ok=True)
            for f in files:
                d = os.path.join(dst, rel, f)
                if not os.path.exists(d):
                    shutil.copy2(os.path.join(root, f), d)
                    if li == len(layers) - 1 and li > 0:
                        borrowed.append(os.path.normpath(os.path.join(name, rel, f)))


def run(*a, **k):
    subprocess.run(a, check=True, **k)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--build", help="ninja out dir (default REPO/build/ios-app)")
    ap.add_argument("--official", required=True, help="unzipped official Madeira.app (for Apple-compiled resources)")
    ap.add_argument("--overlay", help="tree whose app/Madeira holds the Linux-built PE folders")
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ldid", default=os.path.expanduser("~/tools/bin/ldid"))
    a = ap.parse_args()

    repo = os.path.abspath(a.repo)
    build = os.path.abspath(a.build or os.path.join(repo, "build/ios-app"))
    proj = Project(os.path.join(repo, "app/Madeira.xcodeproj/project.pbxproj"))
    app_t, hlp_t = proj.target("Madeira"), proj.target("MadeiraJITHelper")
    env = dict(proj.settings(app_t, a.config)); env["SRCROOT"] = proj.root_dir
    env.update(PRODUCT_NAME="Madeira", EXECUTABLE_NAME="Madeira", TARGET_NAME="Madeira")
    henv = dict(proj.settings(hlp_t, a.config)); henv["SRCROOT"] = proj.root_dir
    henv.update(PRODUCT_NAME="MadeiraJITHelper", EXECUTABLE_NAME="MadeiraJITHelper", DEVELOPMENT_LANGUAGE="en")
    # EXPANDED values: MADEIRA_BUNDLE_IDENTIFIER lives in the project-level settings
    for e in (env, henv):
        e["PRODUCT_BUNDLE_IDENTIFIER"] = expand(e["PRODUCT_BUNDLE_IDENTIFIER"], e)

    appdir = os.path.join(build, "Payload", "Madeira.app")
    shutil.rmtree(os.path.join(build, "Payload"), ignore_errors=True)
    os.makedirs(appdir)
    res_src = os.path.join(proj.root_dir, "Madeira")
    overlay = os.path.join(os.path.abspath(a.overlay), "") if a.overlay else None
    official = os.path.abspath(a.official)
    layers = [res_src, overlay[:-1] if overlay else None, official]
    borrowed = []
    report = []

    # executable
    shutil.copy2(os.path.join(build, "bin/Madeira"), os.path.join(appdir, "Madeira"))

    # Info.plist: source file with $(VARS) expanded, plus the keys Xcode adds (copied from the official one)
    info = subst(plistlib.load(open(os.path.join(proj.root_dir, expand(env["INFOPLIST_FILE"], env)), "rb")), env)
    off = plistlib.load(open(os.path.join(official, "Info.plist"), "rb"))
    added = [k for k in off if k not in info]
    for k in added:
        info[k] = off[k]
    report.append(f"Info.plist: keys added from the official one (Xcode-generated): {', '.join(sorted(added))}")
    with open(os.path.join(appdir, "Info.plist"), "wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
    open(os.path.join(appdir, "PkgInfo"), "w").write("APPL????")

    # resources from the Resources build phase
    for ph in proj.phase(app_t, "PBXResourcesBuildPhase"):
        for ref, _ in proj.phase_files(ph):
            o = proj.objs[ref]
            p = proj.real_path(ref)
            nm = os.path.basename(p)
            if nm == "Assets.xcassets":
                continue  # -> Assets.car + icons from the official IPA below
            if o.get("lastKnownFileType") == "folder":
                copy_tree_layers(nm, layers, os.path.join(appdir, nm), borrowed)
            else:
                shutil.copy2(p, os.path.join(appdir, nm))
    # Apple-compiler products
    for f in ["default.metallib", "Assets.car", "AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"]:
        shutil.copy2(os.path.join(official, f), os.path.join(appdir, f))
        borrowed.append(f)

    # StikJIT framework: the ios-arm64 slice of the xcframework, plus an Info.plist (script "Embed StikJIT")
    fw_src = os.path.join(proj.root_dir, "Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework")
    fw_dst = os.path.join(appdir, "Frameworks/StikJIT.framework")
    shutil.copytree(fw_src, fw_dst, symlinks=True)
    if not os.path.exists(os.path.join(fw_dst, "Info.plist")):
        plistlib.dump({
            "CFBundleExecutable": "StikJIT", "CFBundleIdentifier": info["CFBundleIdentifier"] + ".StikJIT",
            "CFBundleName": "StikJIT", "CFBundlePackageType": "FMWK", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "26.0"},
            open(os.path.join(fw_dst, "Info.plist"), "wb"), fmt=plistlib.FMT_BINARY)

    # JIT helper appex
    ax = os.path.join(appdir, "PlugIns/MadeiraJITHelper.appex")
    os.makedirs(ax)
    shutil.copy2(os.path.join(build, "bin/MadeiraJITHelper"), os.path.join(ax, "MadeiraJITHelper"))
    hinfo = subst(plistlib.load(open(os.path.join(proj.root_dir, expand(henv["INFOPLIST_FILE"], henv)), "rb")), henv)
    hoff = plistlib.load(open(os.path.join(official, "PlugIns/MadeiraJITHelper.appex/Info.plist"), "rb"))
    hadded = [k for k in hoff if k not in hinfo]
    for k in hadded:
        hinfo[k] = hoff[k]
    report.append(f"appex Info.plist: keys added from the official one: {', '.join(sorted(hadded))}")
    with open(os.path.join(ax, "Info.plist"), "wb") as f:
        plistlib.dump(hinfo, f, fmt=plistlib.FMT_BINARY)

    # script phase "Sign bundled dylibs" (licence staleness check)
    for pair in ("COPYING:LICENSE-MADEIRA-GPL-3.0.txt", "LICENSE-EXCEPTION.md:LICENSE-MADEIRA-EXCEPTION.txt"):
        s, d = pair.split(":")
        if not os.path.isfile(os.path.join(appdir, "licenses", d)) or \
           open(os.path.join(repo, s), "rb").read() != open(os.path.join(appdir, "licenses", d), "rb").read():
            sys.exit(f"bundled {d} missing or stale; run build/stage-licenses.sh")

    # ad-hoc signing with entitlements (the user's sideloader re-signs)
    ent_src = os.path.join(proj.root_dir, expand(env["CODE_SIGN_ENTITLEMENTS"], env))
    # Parity with the release: its signature carries only the entitlements its provisioning allowed
    # (the source file also lists com.apple.security.cs.allow-jit). Keep ours to that set.
    ent = ent_src
    try:
        want = plistlib.loads(subprocess.run([a.ldid, "-e", os.path.join(official, "Madeira")],
                                             capture_output=True, check=True).stdout)
        mine = plistlib.load(open(ent_src, "rb"))
        kept = {k: v for k, v in mine.items() if k in want}
        dropped = sorted(set(mine) - set(kept))
        ent = os.path.join(build, "entitlements.plist")
        plistlib.dump(kept, open(ent, "wb"))
        report.append(f"entitlements: signed with {sorted(kept)}; dropped (absent in the official signature): {dropped}")
    except Exception as e:  # official binary unsigned/unreadable: use the source file as is
        report.append(f"entitlements: using the source file unchanged ({e})")
    for dyl in [os.path.join(appdir, "d3d12/libmetalirconverter.dylib"), os.path.join(fw_dst, "StikJIT"), os.path.join(ax, "MadeiraJITHelper")]:
        if os.path.exists(dyl):
            run(a.ldid, "-S", dyl)
    run(a.ldid, "-S" + ent, os.path.join(appdir, "Madeira"))

    # zip
    if os.path.exists(a.out):
        os.remove(a.out)
    with zipfile.ZipFile(a.out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(os.path.join(build, "Payload")):
            dirs.sort()
            for f in sorted(files):
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, build))
    print("\n".join(report))
    open(os.path.join(build, "borrowed-from-official.txt"), "w").write("\n".join(sorted(borrowed)) + "\n")
    print(f"{len(borrowed)} files taken from the official IPA (list: {os.path.join(build, 'borrowed-from-official.txt')})")
    print("IPA:", a.out, os.path.getsize(a.out), "bytes")


if __name__ == "__main__":
    main()
