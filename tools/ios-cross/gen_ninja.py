#!/usr/bin/env python3
"""PLAYBOOK 5.2/5.3: emit build.ninja for app/Madeira.xcodeproj without Xcode.

Reads the project (sources, link inputs, build settings) and writes rules that call the
toolchain from tools/ios-cross/env.sh: one WMO swiftc per target, the clang shim for C/ObjC,
and swiftc as linker driver (ld64.lld). Packaging is done by bundle.py.

usage: gen_ninja.py --repo ~/madeira-ios [--config Debug] [--out DIR]
Environment (see env.sh): IOS_SDK, SWIFT_RES (merged resource dir), XTOOL_TOOLSET, IOS_SHIMS.
"""
import argparse, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pbxproj import Project


def expand(val, env, depth=0):
    """Expand $(VAR) / ${VAR} in a build setting string; unknown vars -> ''. $(inherited) -> ''."""
    if isinstance(val, list):
        return [expand(v, env, depth) for v in val if expand(v, env, depth) != ""]
    if depth > 10:
        return val
    def rep(m):
        name = m.group(1) or m.group(2)
        if name == "inherited":
            return ""
        v = env.get(name, "")
        if isinstance(v, list):
            v = " ".join(expand(x, env, depth + 1) for x in v)
        return expand(v, env, depth + 1)
    return re.sub(r"\$\(([A-Za-z0-9_]+)\)|\$\{([A-Za-z0-9_]+)\}", rep, val)


def q(s):  # shell-quote for ninja command lines
    return "'" + s.replace("'", "'\\''") + "'" if re.search(r"[^A-Za-z0-9_@%+=:,./-]", s) else s


def ninja_escape(p):
    return p.replace("$", "$$").replace(" ", "$ ").replace(":", "$:")


class Gen:
    def __init__(self, a):
        self.a = a
        self.repo = os.path.abspath(a.repo)
        self.proj = Project(os.path.join(self.repo, "app", "Madeira.xcodeproj", "project.pbxproj"))
        self.srcroot = self.proj.root_dir
        self.out = os.path.abspath(a.out or os.path.join(self.repo, "build", "ios-app"))
        self.sdk = os.environ.get("IOS_SDK", os.path.expanduser("~/ios-sdk/iPhoneOS.sdk"))
        # The SDK's own version, stamped into every binary (LC_BUILD_VERSION "sdk"). iOS 26+ draws
        # Liquid Glass only for an app linked against an iOS 26+ SDK; without this stamp swiftc's
        # link leaves "sdk" equal to the deployment target (17.0) and the app gets the old look.
        try:
            with open(os.path.join(self.sdk, "SDKSettings.json"), encoding="utf-8") as f:
                self.sdk_version = json.load(f)["Version"]
        except (OSError, KeyError, ValueError):
            self.sdk_version = None
        self.res = os.environ.get("SWIFT_RES", os.path.expanduser("~/swift-res"))
        # LLVM's ld64.lld: the ones in the Swift toolchain and in xtool's toolset reject platform iOS
        self.lld = os.environ.get("IOS_LLD", "/usr/lib/llvm-20/bin/ld64.lld")
        self.rt_src = os.path.join(self.repo, "toolchains/llvm-project/compiler-rt/lib/builtins/os_version_check.c")
        self.shims = os.environ.get("IOS_SHIMS", os.path.expanduser("~/ios-shims"))
        self.lines = []

    # ------------------------------------------------------------------ helpers
    def env_for(self, target):
        s = dict(self.proj.settings(target, self.a.config))
        s["SRCROOT"] = self.srcroot
        s["PROJECT_DIR"] = self.srcroot
        s["TARGET_NAME"] = target["name"]
        s["EXECUTABLE_NAME"] = target["name"]
        s.setdefault("PRODUCT_NAME", target["name"])
        return s

    def w(self, s=""):
        self.lines.append(s)

    def search_paths(self, env, key):
        v = env.get(key, [])
        if isinstance(v, str):
            v = [v]
        return [p for p in expand(v, env) if p]

    def imported_frameworks(self, srcs, extra_dirs):
        """Frameworks named in #import/#include <Name/...> of ObjC/C sources and the headers next
        to them. Xcode autolinks these through modules; without -fmodules we must link them."""
        found = set()
        fw_dir = os.path.join(self.sdk, "System/Library/Frameworks")
        pat = re.compile(r'^\s*#\s*(?:import|include)\s*<([A-Za-z0-9_]+)/', re.M)
        files = set(srcs)
        for d in extra_dirs:
            files.update(self.headers_of(d))
        for f in files:
            try:
                txt = open(f, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in pat.finditer(txt):
                if os.path.isdir(os.path.join(fw_dir, m.group(1) + ".framework")):
                    found.add(m.group(1))
        return found

    def find_lib(self, name, libdirs):
        for d in libdirs + [self.srcroot, os.path.join(self.srcroot, "Madeira")]:
            p = os.path.normpath(os.path.join(d, name))
            if os.path.exists(p):
                return p
        raise SystemExit(f"gen_ninja: {name} not found in {libdirs}; build it first (PLAYBOOK phase 3)")

    # ------------------------------------------------------------------ one target
    def target(self, name, exe_name):
        proj, t = self.proj, self.proj.target(name)
        env = self.env_for(t)
        tgt_ver = expand(env.get("IPHONEOS_DEPLOYMENT_TARGET", "17.0"), env)
        triple = f"arm64-apple-ios{tgt_ver}"
        defs = [d for d in expand(env.get("GCC_PREPROCESSOR_DEFINITIONS", []), env)]
        swift_conds = expand(env.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""), env).split()
        hdr = [p for p in self.search_paths(env, "HEADER_SEARCH_PATHS")]
        libdirs = [p for p in self.search_paths(env, "LIBRARY_SEARCH_PATHS")]
        fwdirs = [p for p in self.search_paths(env, "FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]")]
        cxx_std = expand(env.get("CLANG_CXX_LANGUAGE_STANDARD", "gnu++17"), env)
        arc = env.get("CLANG_ENABLE_OBJC_ARC") == "YES"
        opt = "-O" + str(expand(env.get("GCC_OPTIMIZATION_LEVEL", "0"), env))
        swift_opt = expand(env.get("SWIFT_OPTIMIZATION_LEVEL", "-O"), env)
        bridging = expand(env.get("SWIFT_OBJC_BRIDGING_HEADER", ""), env)
        swiftv = expand(env.get("SWIFT_VERSION", "5.0"), env)
        ext_only = env.get("APPLICATION_EXTENSION_API_ONLY") == "YES"

        objd = os.path.join(self.out, "obj", name)
        swift_files, c_objs = [], []
        for ph in proj.phase(t, "PBXSourcesBuildPhase"):
            for ref, _ in proj.phase_files(ph):
                p = proj.real_path(ref)
                ext = os.path.splitext(p)[1]
                if ext == ".swift":
                    swift_files.append(p)
                elif ext in (".c", ".m", ".mm", ".cpp"):
                    c_objs.append(p)
                elif ext == ".metal":
                    pass  # precompiled: default.metallib comes from the official IPA (bundle.py)
                else:
                    sys.exit(f"gen_ninja: unhandled source {p}")

        clang_common = [f"-miphoneos-version-min={tgt_ver}", "-arch", "arm64", "-isysroot", self.sdk, "-g", opt,
                        "-fblocks", "-fno-common", "-Wno-everything"]
        if ext_only:
            clang_common.append("-fapplication-extension")
        for d in defs:
            clang_common.append("-D" + d)
        for h in hdr:
            clang_common += ["-I", h]
        for f in fwdirs:
            clang_common += ["-F", f]
        objs = []
        for src in c_objs:
            ext = os.path.splitext(src)[1]
            o = os.path.join(objd, os.path.relpath(src, self.srcroot).replace("/", "_") + ".o")
            objs.append(o)
            flags = list(clang_common)
            drv = "ios-clang"
            if ext in (".m", ".mm") and arc:
                flags.append("-fobjc-arc")
            if ext == ".mm" or ext == ".cpp":
                drv = "ios-clang++"
                flags.append("-std=" + cxx_std)
            elif ext == ".m" or ext == ".c":
                flags.append("-std=gnu17")
            self.w(f"build {ninja_escape(o)}: cc {ninja_escape(src)}")
            self.w(f"  drv = {os.path.join(self.shims, drv)}")
            self.w(f"  flags = {' '.join(q(f) for f in flags)}")
        # swift
        sw_obj = os.path.join(objd, f"{name}.swift.o")
        sflags = ["-module-name", name, "-target", triple, "-sdk", self.sdk, "-resource-dir", os.path.join(self.res, "lib", "swift"),
                  "-Xfrontend", "-enable-cross-import-overlays",
                  "-swift-version", swiftv.split(".")[0], swift_opt, "-g", "-parse-as-library", "-wmo",
                  "-enable-testing"]
        for c in swift_conds:
            if c:
                sflags += ["-D", c]
        if ext_only:
            sflags.append("-application-extension")
        for h in hdr:
            sflags += ["-Xcc", "-I" + h]
        for f in fwdirs:
            sflags += ["-F", f]
        implicit = []
        if bridging:
            bh = os.path.join(self.srcroot, bridging)
            sflags += ["-import-objc-header", bh]
            implicit = self.headers_of(os.path.dirname(bh)) + [bh]
        self.w(f"build {ninja_escape(sw_obj)}: swiftc {' '.join(ninja_escape(s) for s in swift_files)}"
               + (" | " + " ".join(ninja_escape(i) for i in implicit) if implicit else ""))
        self.w(f"  flags = {' '.join(q(f) for f in sflags)}")
        objs.append(sw_obj)
        # link
        link = ["-target", triple, "-sdk", self.sdk, "-resource-dir", os.path.join(self.res, "lib", "swift"),
                "-use-ld=" + self.lld, "-Xclang-linker", "-mlinker-version=1000"]
        if self.sdk_version:
            link += ["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", tgt_ver, "-Xlinker", self.sdk_version]
        ldflags = expand(env.get("LD_RUNPATH_SEARCH_PATHS", []), env)
        for r in ldflags:
            link += ["-Xlinker", "-rpath", "-Xlinker", r]
        for d in libdirs:
            link.append("-L" + d)
        for f in fwdirs:
            link.append("-F" + f)
        if ext_only:
            link += ["-application-extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]
        inputs = []
        for ph in proj.phase(t, "PBXFrameworksBuildPhase"):
            for ref, st in proj.phase_files(ph):
                o = proj.objs[ref]
                nm = o.get("name") or os.path.basename(o.get("path", ""))
                kind = o.get("lastKnownFileType", "")
                weak = "Weak" in st.get("ATTRIBUTES", [])
                if kind == "archive.ar":
                    p = self.find_lib(nm, libdirs)
                    link.append(p)
                    inputs.append(p)
                elif kind == "wrapper.framework":
                    fw = nm.replace(".framework", "")
                    link += (["-Xlinker", "-weak_framework", "-Xlinker", fw] if weak else ["-framework", fw])
                elif kind == "sourcecode.text-based-dylib-definition":
                    link.append("-l" + re.sub(r"^lib|\.tbd$", "", nm))
                elif kind == "wrapper.xcframework":
                    pass  # StikJIT: -framework via OTHER_LDFLAGS below
                else:
                    sys.exit(f"gen_ninja: unhandled link input {nm} ({kind})")
        listed = {link[i + 1] for i, x in enumerate(link) if x == "-framework"}
        listed |= {link[i + 1] for i, x in enumerate(link) if x == "-weak_framework"}
        srcdirs = {os.path.dirname(s) for s in c_objs}
        for fw in sorted(self.imported_frameworks(c_objs, srcdirs) - listed):
            link += ["-framework", fw]
        olf = env.get("OTHER_LDFLAGS[sdk=iphoneos*]", env.get("OTHER_LDFLAGS", []))
        link += expand([olf] if isinstance(olf, str) else olf, env)
        # ___isPlatformVersionAtLeast (generated for #available) is only in Apple's libclang_rt.ios.a
        rt_obj = os.path.join(objd, "os_version_check.o")
        self.w(f"build {ninja_escape(rt_obj)}: cc {ninja_escape(self.rt_src)}")
        self.w(f"  drv = {os.path.join(self.shims, 'ios-clang')}")
        self.w(f"  flags = -miphoneos-version-min={tgt_ver} -arch arm64 -O2")
        objs.append(rt_obj)
        exe = os.path.join(self.out, "bin", exe_name)
        self.w(f"build {ninja_escape(exe)}: link {' '.join(ninja_escape(o) for o in objs)}"
               + (" | " + " ".join(ninja_escape(i) for i in inputs) if inputs else ""))
        self.w(f"  flags = {' '.join(q(f) for f in link)}")
        self.w()
        return exe

    def headers_of(self, d):
        out = []
        for root, _, files in os.walk(d):
            out += [os.path.join(root, f) for f in files if f.endswith(".h")]
        return sorted(out)

    def clang_res(self):
        d = os.path.join(self.res, "lib", "clang")
        return os.path.join(d, sorted(os.listdir(d))[0])

    def run(self):
        w = self.w
        w("# generated by tools/ios-cross/gen_ninja.py -- do not edit")
        w("ninja_required_version = 1.10")
        w(f"swiftc = {os.environ.get('SWIFTC', 'swiftc')}")
        w("rule cc")
        w("  command = $drv $flags -MD -MF $out.d -c $in -o $out")
        w("  depfile = $out.d")
        w("  deps = gcc")
        w("  description = CC $in")
        w("rule swiftc")
        w("  command = $swiftc -c $flags $in -o $out")
        w("  description = SWIFT $out")
        w("rule link")
        w("  command = $swiftc $flags $in -o $out")
        w("  description = LINK $out")
        w()
        app = self.target("Madeira", "Madeira")
        helper = self.target("MadeiraJITHelper", "MadeiraJITHelper")
        w(f"build all: phony {ninja_escape(app)} {ninja_escape(helper)}")
        w("default all")
        os.makedirs(self.out, exist_ok=True)
        with open(os.path.join(self.out, "build.ninja"), "w") as f:
            f.write("\n".join(self.lines) + "\n")
        print("wrote", os.path.join(self.out, "build.ninja"))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--out")
    Gen(ap.parse_args()).run()
