"""Minimal reader for Xcode's old-style (OpenStep plist) project.pbxproj.

Only what tools/ios-cross/gen_ninja.py needs: parse the file, resolve group paths to
real paths, list a target's build phases, and merge build settings (project -> target).
"""
import re

_TOKEN = re.compile(r'''
    (?P<ws>\s+)
  | (?P<comment>/\*.*?\*/|//[^\n]*)
  | (?P<str>"(?:\\.|[^"\\])*")
  | (?P<sym>[{}()=;,])
  | (?P<word>[^\s{}()=;,"]+)
''', re.X | re.S)


def _tokens(text):
    for m in _TOKEN.finditer(text):
        k = m.lastgroup
        if k in ("ws", "comment"):
            continue
        v = m.group()
        if k == "str":
            v = re.sub(r'\\(.)', lambda mm: {"n": "\n", "t": "\t"}.get(mm.group(1), mm.group(1)), v[1:-1])
            yield ("s", v)
        else:
            yield (k, v)


def parse(text):
    toks = list(_tokens(text.split("\n", 1)[1] if text.startswith("//") else text))
    pos = 0

    def value():
        nonlocal pos
        k, v = toks[pos]
        if k == "sym" and v == "{":
            pos += 1
            d = {}
            while toks[pos] != ("sym", "}"):
                key = toks[pos][1]
                assert toks[pos + 1] == ("sym", "="), (key, toks[pos + 1])
                pos += 2
                d[key] = value()
                assert toks[pos] == ("sym", ";"), (key, toks[pos])
                pos += 1
            pos += 1
            return d
        if k == "sym" and v == "(":
            pos += 1
            a = []
            while toks[pos] != ("sym", ")"):
                a.append(value())
                if toks[pos] == ("sym", ","):
                    pos += 1
            pos += 1
            return a
        pos += 1
        return v

    return value()


class Project:
    def __init__(self, path):
        import os
        self.path = path
        self.root_dir = os.path.dirname(os.path.dirname(os.path.abspath(path)))  # SRCROOT
        d = parse(open(path, encoding="utf-8").read())
        self.objs = d["objects"]
        self.root = self.objs[d["rootObject"]]
        # parent map for group path resolution
        self.parent = {}
        for oid, o in self.objs.items():
            for c in o.get("children", []) if isinstance(o.get("children"), list) else []:
                self.parent[c] = oid

    def real_path(self, oid):
        """Absolute path of a PBXFileReference / PBXGroup, honouring sourceTree."""
        import os
        o = self.objs[oid]
        tree = o.get("sourceTree", "<group>")
        p = o.get("path", "")
        if tree == "SOURCE_ROOT":
            return os.path.normpath(os.path.join(self.root_dir, p))
        if tree == "<absolute>":
            return p
        if tree == "BUILT_PRODUCTS_DIR" or tree == "SDKROOT" or tree == "DEVELOPER_DIR":
            return None
        base = self.root_dir
        par = self.parent.get(oid)
        if par is not None:
            pp = self.real_path(par)
            if pp:
                base = pp
        return os.path.normpath(os.path.join(base, p)) if p else base

    def target(self, name):
        for t in self.root["targets"]:
            if self.objs[t]["name"] == name:
                return self.objs[t]
        raise KeyError(name)

    def phase(self, target, isa, name=None):
        out = []
        for ph in target["buildPhases"]:
            o = self.objs[ph]
            if o["isa"] == isa and (name is None or o.get("name") == name):
                out.append(o)
        return out

    def phase_files(self, phase):
        """[(fileRef object id, PBXBuildFile settings)] for a build phase."""
        res = []
        for bf in phase["files"]:
            b = self.objs[bf]
            res.append((b["fileRef"], b.get("settings", {})))
        return res

    def settings(self, target, config):
        """Project settings overlaid by target settings; values kept as raw strings/lists."""
        def conf(lst_id):
            for c in self.objs[lst_id]["buildConfigurations"]:
                if self.objs[c]["name"] == config:
                    return self.objs[c]["buildSettings"]
            return {}
        s = dict(conf(self.root["buildConfigurationList"]))
        s.update(conf(target["buildConfigurationList"]))
        return s


if __name__ == "__main__":
    import sys, json
    p = Project(sys.argv[1])
    t = p.target(sys.argv[2])
    for isa in ("PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"):
        for ph in p.phase(t, isa):
            print("==", isa)
            for ref, st in p.phase_files(ph):
                o = p.objs[ref]
                print("  ", o.get("lastKnownFileType") or o.get("explicitFileType"), p.real_path(ref), json.dumps(st) if st else "")
