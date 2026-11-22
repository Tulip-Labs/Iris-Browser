#!/usr/bin/env python3
"""The hand-written C bindings against the real headers.

  check.py --headers 'a.h b.h' --cflags '...' --odin-root ROOT [--pkg DIR=IMPORT]... FILE.odin...

For every procedure in a `foreign` block of the given Odin files: the C
function of that name must exist in the headers, take as many parameters,
and each parameter and the result must have the same machine type (an
integer of the same width, a pointer, a float of the same width), which is
what matters for the calling convention. clang reads the headers (its AST
as JSON), so the C side is the compiler's own view, not a guess.

For every Odin struct marked `/// struct NAME` or `/// typedef NAME`: its
size and each field's offset must equal C's sizeof and offsetof. A C
program and an Odin program print them; the two must agree.

Exit status 1 and a list of differences when anything disagrees.
"""
import argparse, json, os, re, subprocess, sys, tempfile

# ---------------------------------------------------------------- Odin side

PRIM = {
    "i8": "i1", "u8": "u1", "b8": "u1", "bool": "u1",
    "i16": "i2", "u16": "u2",
    "i32": "i4", "u32": "u4", "b32": "i4", "rune": "i4", "c.int": "i4", "c.uint": "u4",
    "i64": "i8", "u64": "u8", "int": "i8", "uint": "u8", "uintptr": "u8", "c.long": "i8",
    "c.ulong": "u8", "c.size_t": "u8", "c.ssize_t": "i8",
    "f32": "f4", "f64": "f8", "c.float": "f4", "c.double": "f8",
}


def strip_comments(s):
    return re.sub(r"//[^\n]*", "", s)


class Odin:
    def __init__(self, files):
        self.aliases = {}  # name -> type text
        self.structs = {}  # odin name -> (cname, [fields])
        self.procs = []  # (cname, params, ret, file)
        self.consts = []  # (name, package dir)
        for f in files:
            self.read(f)

    def read(self, path):
        src = open(path).read()
        # aliases and distinct types
        for m in re.finditer(r"^\s*(\w+)\s*::\s*(?:distinct\s+)?([\w.\^\[\]]+)\s*$", strip_comments(src), re.M):
            if m.group(2) not in ("struct", "enum", "union", "proc"):
                self.aliases[m.group(1)] = m.group(2)
        for m in re.finditer(r"^\s*(\w+)\s*::\s*(?:distinct\s+)?enum\s+(\w+)", src, re.M):
            self.aliases[m.group(1)] = m.group(2)
        for m in re.finditer(r"^\s*(\w+)\s*::\s*(?:distinct\s+)?bit_set\[[^;\]]*;\s*(\w+)\]", src, re.M):
            self.aliases[m.group(1)] = m.group(2)
        for m in re.finditer(r"^\s*(\w+)\s*::\s*(?:distinct\s+)?proc\b", src, re.M):
            self.aliases[m.group(1)] = "rawptr"
        # structs marked with the C name
        for m in re.finditer(r"///\s*(struct|typedef|union)\s+(\w+)[^\n]*\n\s*(\w+)\s*::\s*struct[^{]*\{(.*?)\n\s*\}", src, re.S):
            kw, cname, oname, body = m.group(1), m.group(2), m.group(3), m.group(4)
            cname = cname if kw == "typedef" else f"{kw} {cname}"
            fields = []
            for line in strip_comments(body).split("\n"):
                line = line.strip().rstrip(",")
                if not line or ":" not in line or line.startswith("using"):
                    continue
                names, _ = line.split(":", 1)
                for n in names.split(","):
                    n = n.strip()
                    if n and not n.startswith("_"):
                        fields.append(n)
            self.structs[oname] = (cname, fields, os.path.realpath(os.path.dirname(path)))
        # constants named as C names them (checked by value)
        for m in re.finditer(r"^(\w+)\s*::\s*(?:\w+\()?\s*[-(0-9]", strip_comments(src), re.M):
            if re.match(r"^(WPE|WEBKIT|G|DRM|XDG|WL|EGL|GL|XKB|SOUP|JSC)_[A-Z0-9_]+$", m.group(1)):
                self.consts.append((m.group(1), os.path.realpath(os.path.dirname(path))))
        # foreign procedures
        for blk in re.finditer(r"foreign\s+\w+\s*\{(.*?)\n\}", src, re.S):
            body = strip_comments(blk.group(1))
            for m in re.finditer(r"(?:@\(link_name\s*=\s*\"(\w+)\"\)\s*)?(\w+)\s*::\s*proc\s*(?:\"\w+\"\s*)?\((.*?)\)\s*(?:->\s*([^-]+?))?\s*---", body, re.S):
                link, name, params, ret = m.groups()
                self.procs.append((link or name, self.params(params), ret.strip() if ret else None, path))

    def params(self, text):
        out = []
        depth = 0
        cur = ""
        for ch in text:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            if ch == "," and depth == 0:
                out.append(cur)
                cur = ""
            else:
                cur += ch
        if cur.strip():
            out.append(cur)
        res = []
        pending = 0
        for p in out:
            p = p.strip()
            if not p:
                continue
            if ":" in p:
                t = p.split(":", 1)[1].strip()
                t = t.split("=")[0].strip()
                res += [t] * (pending + 1)
                pending = 0
            else:
                pending += 1  # `a, b: i32`
        return res

    def kind(self, t):
        """the machine type of an Odin type: i4, u8, f8, ptr, or s<size> for a struct"""
        if t is None:
            return "void"
        t = t.strip()
        seen = 0
        while True:
            if t.startswith("^") or t.startswith("[^]") or t in ("rawptr", "cstring") or t.startswith("proc") or t.startswith("#type"):
                return "ptr"
            if "." in t and t not in PRIM:
                pkg, nm = t.split(".", 1)
                if t in self.aliases:
                    t = self.aliases[t]
                    continue
                t = self.aliases.get(nm, nm)  # e.g. wl.Fixed -> i32 via alias
                if t == nm and nm in self.structs:
                    return "struct"
                if t == nm:
                    return EXTERN.get(f"{pkg}.{nm}", "?" + f"{pkg}.{nm}")
                continue
            if t in PRIM:
                k = PRIM[t]
                return "i" + k[1] if k[0] in "iu" else k
            if t in self.structs:
                return "struct"
            if t in self.aliases and seen < 20:
                t = self.aliases[t]
                seen += 1
                continue
            if t in EXTERN:
                return EXTERN[t]
            return "?" + t


# types from Odin's vendor packages the bindings use
EXTERN = {
    "egl.Display": "ptr", "egl.Surface": "ptr", "egl.Config": "ptr", "egl.Context": "ptr", "egl.Image": "ptr",
    "egl.Boolean": "i4", "egl.Platform": "i4", "gl.GLenum": "i4", "u32": "i4",
    "linux.Fd": "i4", "posix.pid_t": "i4",
}

# ---------------------------------------------------------------- C side

C_INT = {
    "char": "i1", "signed char": "i1", "unsigned char": "i1", "_Bool": "i1", "bool": "i1",
    "short": "i2", "unsigned short": "i2",
    "int": "i4", "unsigned int": "i4", "long": "i8", "unsigned long": "i8",
    "long long": "i8", "unsigned long long": "i8",
    "float": "f4", "double": "f8", "void": "void",
}


TYPEDEFS = {}


def c_kind(qt, depth=0):
    t = re.sub(r"\b(const|volatile|restrict|__restrict)\b", "", qt).strip()
    t = re.sub(r"\s+", " ", t)
    if t in TYPEDEFS and depth < 20:
        return c_kind(TYPEDEFS[t], depth + 1)
    if "*" in t or "(" in t or t.endswith("]"):
        return "ptr"
    if t.startswith("enum "):
        return "e4"
    if t.startswith("struct ") or t.startswith("union "):
        return "struct"
    t = re.sub(r"\s+", " ", t)
    return C_INT.get(t, "?" + t)


def c_functions(headers, cflags, wanted):
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "all.c")
        open(src, "w").write("".join(f"#include <{h}>\n" for h in headers))
        cmd = ["clang", "-fsyntax-only", "-Xclang", "-ast-dump=json", "-Xclang", "-ast-dump-filter=", src] + cflags.split()
        # one dump of the whole translation unit, read as a stream of top decls
        cmd = ["clang", "-fsyntax-only", "-Xclang", "-ast-dump=json", src] + cflags.split()
        out = subprocess.run(cmd, capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit("clang could not read the headers:\n" + out.stderr[-4000:])
        ast = json.loads(out.stdout)
    funcs = {}
    for n in ast.get("inner", []):
        if n.get("kind") == "TypedefDecl":
            # typedef enum {...} Name: GLib's and WebKit's flags and enums
            if '"kind": "EnumType"' in json.dumps(n.get("inner", [])):
                TYPEDEFS[n["name"]] = "enum " + n["name"]
                continue
            TYPEDEFS[n["name"]] = n["type"].get("desugaredQualType") or n["type"]["qualType"]
    for n in ast.get("inner", []):
        if n.get("kind") == "FunctionDecl" and n.get("name") in wanted:
            t = n["type"].get("desugaredQualType") or n["type"]["qualType"]
            ret = t.split("(", 1)[0].strip()
            params = []
            for p in n.get("inner", []):
                if p.get("kind") == "ParmVarDecl":
                    params.append(p["type"].get("desugaredQualType") or p["type"]["qualType"])
            variadic = n.get("variadic", False)
            funcs[n["name"]] = (ret, params, variadic)
    return funcs


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit(f"{' '.join(cmd[:3])}... failed:\n{r.stdout[-3000:]}\n{r.stderr[-3000:]}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--headers", required=True)
    ap.add_argument("--cflags", default="")
    ap.add_argument("--import", dest="imports", action="append", default=[], help="NAME=PATH of the Odin package with the structs")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    o = Odin(a.files)
    headers = a.headers.split()
    problems = []

    # functions
    wanted = {p[0] for p in o.procs}
    cf = c_functions(headers, a.cflags, wanted)
    for cname, params, ret, path in o.procs:
        where = os.path.basename(path)
        if cname not in cf:
            problems.append(f"{where}: {cname} is not in the headers")
            continue
        cret, cparams, variadic = cf[cname]
        if variadic:
            problems.append(f"{where}: {cname} takes C varargs (call another form)")
        if len(cparams) != len(params):
            problems.append(f"{where}: {cname} takes {len(cparams)} parameters in C, {len(params)} in Odin")
            continue
        for i, (cp, op) in enumerate(zip(cparams, params)):
            ck, ok = c_kind(cp), o.kind(op)
            if ck != ok and not (ck == "e4" and ok in ("i4", "u4")):
                problems.append(f"{where}: {cname} parameter {i + 1}: C {cp} ({ck}) vs Odin {op} ({ok})")
        ck, ok = c_kind(cret), o.kind(ret)
        if ck != ok and not (ck == "e4" and ok in ("i4", "u4")):
            problems.append(f"{where}: {cname} returns C {cret} ({ck}) vs Odin {ret} ({ok})")

    # structs: sizes and offsets from C and from Odin
    if o.structs or o.consts:
        with tempfile.TemporaryDirectory() as d:
            c = ["#include <stdio.h>", "#include <stddef.h>"] + [f"#include <{h}>" for h in headers] + ["int main(void){"]
            od = ["package abi_structs", 'import "core:fmt"'] + [f'import {imp.split("=")[0]} "chk{k}:{os.path.basename(imp.split("=")[1].rstrip("/"))}"' for k, imp in enumerate(a.imports)] + ["main :: proc() {"]
            pkgs = {os.path.realpath(imp.split("=")[1]): imp.split("=")[0] for imp in a.imports}
            for oname, (cname, fields, sdir) in sorted(o.structs.items()):
                if sdir not in pkgs:
                    problems.append(f"struct {oname}: its package ({sdir}) is not given with --import")
                    continue
                pkg = pkgs[sdir]
                ct = cname
                c.append(f'printf("{oname} size %zu\\n", sizeof({ct}));')
                od.append(f'fmt.printfln("{oname} size %d", size_of({pkg}.{oname}))')
                for f in fields:
                    c.append(f'printf("{oname}.{f} %zu\\n", offsetof({ct}, {f}));')
                    od.append(f'fmt.printfln("{oname}.{f} %d", offset_of({pkg}.{oname}, {f}))')
            for name, cdir in o.consts:
                if cdir not in pkgs:
                    continue
                c.append(f'#ifdef {name}\nprintf("{name} %lld\\n", (long long)({name}));\n#else\nprintf("{name} %lld\\n", (long long)({name}));\n#endif')
                od.append(f'fmt.printfln("{name} %d", i64({pkgs[cdir]}.{name}))')
            c.append("return 0;}")
            od.append("}")
            open(os.path.join(d, "s.c"), "w").write("\n".join(c) + "\n")
            os.makedirs(os.path.join(d, "o"))
            open(os.path.join(d, "o", "s.odin"), "w").write("\n".join(od) + "\n")
            run(["cc", "-o", os.path.join(d, "sc"), os.path.join(d, "s.c")] + a.cflags.split())
            cout = run([os.path.join(d, "sc")]).splitlines()
            cols = [f"-collection:chk{k}=" + os.path.dirname(imp.split("=")[1].rstrip("/")) for k, imp in enumerate(a.imports)]
            r = subprocess.run(["odin", "build", os.path.join(d, "o"), "-out:" + os.path.join(d, "so"), "-o:none"] + cols, capture_output=True, text=True)
            if r.returncode != 0:
                problems.append("the Odin packages do not compile:\n" + (r.stdout + r.stderr)[-1500:])
                oout = []
            else:
                oout = run([os.path.join(d, "so")]).splitlines()
            for x, y in zip(cout, oout):
                if x != y:
                    problems.append(f"struct layout: C says '{x}', Odin says '{y}'")
            if oout and len(cout) != len(oout):
                problems.append("struct layout: different numbers of lines")

    n_f = len(o.procs)
    n_s = len(o.structs)
    if problems:
        print(f"ABI check: {len(problems)} problem(s) in {n_f} functions and {n_s} structs:")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print(f"ABI check: {n_f} functions and {n_s} structs match the C headers")


if __name__ == "__main__":
    main()
