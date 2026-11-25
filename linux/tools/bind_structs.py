#!/usr/bin/env python3
"""Odin structs and enum values for a C API made of structs of function
pointers (CEF's C API), from clang's reading of the headers.

  bind_structs.py OUT.odin NAMES.txt --headers '...' --cflags '...' [--package iris]

NAMES.txt lists, one per line (# for comments):
  struct cef_browser_t      a struct, every field in C's order; a function
                            pointer becomes a typed `proc "c"`, its
                            parameter names read from the header's text
  enum cef_paint_element_type_t   the enum's values, as constants
Pointers to structs listed here are typed (^cef_frame_t); pointers to any
other struct become rawptr. Each struct is marked `/// struct _name` so
abi/check.py holds its size and offsets to C's. The output is committed.
"""
import argparse, json, os, re, subprocess, sys, tempfile

INTS = {
    "char": "u8", "signed char": "i8", "unsigned char": "u8", "_Bool": "b8",
    "short": "i16", "unsigned short": "u16", "int": "i32", "unsigned int": "u32",
    "long": "int", "unsigned long": "uint", "long long": "i64", "unsigned long long": "u64",
    "float": "f32", "double": "f64",
    "int8_t": "i8", "uint8_t": "u8", "int16_t": "i16", "uint16_t": "u16", "char16_t": "u16",
    "int32_t": "i32", "uint32_t": "u32", "int64_t": "i64", "uint64_t": "u64", "size_t": "uint",
}
# CEF's own typedefs kept by name (declared in the output)
KEEP = {"cef_string_t": "cef_string_utf16_t", "cef_char_t": "u16"}
KEYWORDS = {"proc", "map", "context", "struct", "union", "enum", "in", "not_in", "where", "when", "defer",
            "using", "package", "import", "foreign", "return", "for", "if", "else", "switch", "case", "cast",
            "matrix", "distinct", "dynamic", "transmute", "auto_cast", "or_else", "or_return", "bit_set",
            "bit_field", "fallthrough", "break", "continue", "do"}


def clean(t):
    t = re.sub(r"\b(const|volatile|restrict|__restrict)\b", "", t)
    return re.sub(r"\s+", " ", t).strip()


def split_top(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out]


class Unlisted(Exception):
    pass


class Gen:
    def __init__(self, typedefs, enums, structs_wanted):
        self.typedefs = typedefs  # name -> qualType
        self.enums = enums  # typedef names that are enums
        self.wanted = structs_wanted  # typedef names (cef_x_t)

    def struct_name(self, t):
        """'struct _cef_x_t' or 'cef_x_t' -> 'cef_x_t' when it is one of ours"""
        m = re.fullmatch(r"struct _(\w+)", t)
        n = m.group(1) if m else t
        return n if n in self.wanted else None

    def odin(self, qt, depth=0):
        t = clean(qt)
        if t in KEEP:
            return "cef_string_t" if t == "cef_string_t" else KEEP[t]
        if t in INTS:
            return INTS[t]
        if t == "void":
            return None
        if "(*)" in t:
            return "rawptr"  # a callback inside a callback's parameters
        m = re.fullmatch(r"(.*)\[(\d+)\]", t)
        if m:
            return f"[{m.group(2)}]{self.odin(m.group(1), depth + 1)}"
        if t.endswith("*"):
            base = clean(t[:-1])
            if base in ("char",):
                return "cstring"
            if base == "void":
                return "rawptr"
            try:
                inner = self.odin(base, depth + 1)
            except Unlisted:
                return "rawptr"  # a struct Iris does not use: opaque
            if inner is None or inner == "rawptr" and not base.endswith("*"):
                return "rawptr"
            return "^" + inner
        n = self.struct_name(t)
        if n:
            return n
        if t.startswith("enum ") or t in self.enums:
            return "i32"
        if t in self.typedefs and depth < 20:
            r = self.odin(self.typedefs[t], depth + 1)
            if r is not None:
                return r
        if t.startswith("struct "):
            raise Unlisted(t)
        sys.exit(f"no Odin type for C {qt!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("names")
    ap.add_argument("--headers", required=True)
    ap.add_argument("--cflags", default="")
    ap.add_argument("--package", default="iris")
    a = ap.parse_args()
    structs, enums = [], []
    for line in open(a.names):
        line = line.split("#")[0].split()
        if len(line) == 2:
            (structs if line[0] == "struct" else enums).append(line[1])
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "all.c")
        open(src, "w").write("".join(f"#include \"{h}\"\n" for h in a.headers.split()))
        out = subprocess.run(["clang", "-fsyntax-only", "-Xclang", "-ast-dump=json", src] + a.cflags.split(), capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit("clang could not read the headers:\n" + out.stderr[-4000:])
        ast = json.loads(out.stdout)
    typedefs, enum_names, records, enum_decls = {}, set(), {}, {}
    for n in ast.get("inner", []):
        k = n.get("kind")
        if k == "TypedefDecl":
            typedefs[n["name"]] = n["type"].get("desugaredQualType") or n["type"]["qualType"]
            if '"kind": "EnumType"' in json.dumps(n.get("inner", [])) or typedefs[n["name"]].startswith("enum "):
                enum_names.add(n["name"])
                inner = n.get("inner", [])
                decl = inner[0].get("ownedTagDecl") or (inner[0].get("decl") if inner else None) if inner else None
                if decl:
                    enum_decls.setdefault(n["name"], decl.get("id"))
        elif k == "RecordDecl" and n.get("completeDefinition") and n.get("name"):
            records[n["name"]] = n
        elif k == "EnumDecl":
            enum_decls[n.get("id")] = n
    # header text, for parameter names
    text = ""
    for root in re.findall(r"-I(\S+)", a.cflags):
        for dp, _, fs in os.walk(os.path.join(root, "include")):
            for f in fs:
                if f.endswith(".h"):
                    text += open(os.path.join(dp, f), errors="replace").read() + "\n"
    g = Gen(typedefs, enum_names, set(structs))
    o = [f"// Generated by tools/bind_structs.py from the C headers ({os.path.basename(a.names)}).",
         "// Do not edit: list a struct or enum there and run tools/bind_cef.sh.",
         f"package {a.package}", "", "cef_string_t :: cef_string_utf16_t", ""]
    for s in structs:
        r = records.get("_" + s)
        if r is None:
            sys.exit(f"struct _{s} is not in the headers")
        m = re.search(r"typedef struct _" + s + r" \{(.*?)\n\} " + s + ";", text, re.S)
        body = m.group(1) if m else ""
        o.append(f"/// struct _{s}")
        o.append(f"{s} :: struct {{")
        for f in r.get("inner", []):
            if f.get("kind") != "FieldDecl":
                continue
            name = f["name"]
            qt = f["type"].get("desugaredQualType") or f["type"]["qualType"]
            on = name + "_" if name in KEYWORDS else name
            fm = re.fullmatch(r"(.*?)\(\*\)\((.*)\)", clean(qt))
            if fm:
                ret = g.odin(fm.group(1))
                ps = [p for p in split_top(fm.group(2)) if p != "void"]
                names = []
                pm = re.search(r"\(\s*CEF_CALLBACK\s*\*\s*" + name + r"\s*\)\s*\((.*?)\)\s*;", body, re.S)
                if pm:
                    names = [re.findall(r"\w+", x)[-1] for x in split_top(re.sub(r"//[^\n]*", "", pm.group(1))) if x]
                if len(names) != len(ps):
                    names = [f"p{i}" for i in range(len(ps))]
                params = ", ".join(f"{(n + '_') if n in KEYWORDS else n}: {g.odin(p)}" for n, p in zip(names, ps))
                o.append(f"\t{on}: proc \"c\" ({params})" + (f" -> {ret}," if ret else ","))
            else:
                o.append(f"\t{on}: {g.odin(qt)},")
        o.append("}")
        o.append("")
    for e in enums:
        decl = enum_decls.get(e)
        decl = enum_decls.get(decl) if isinstance(decl, str) else decl
        if decl is None:
            sys.exit(f"enum {e} is not in the headers")
        o.append(f"// {e}")
        val = -1
        for c in decl.get("inner", []):
            if c.get("kind") != "EnumConstantDecl":
                continue
            v = None
            for x in c.get("inner", []):
                if x.get("kind") == "ConstantExpr" and "value" in x:
                    v = int(x["value"])
            val = v if v is not None else val + 1
            o.append(f"{c['name']} :: {val}")
        o.append("")
    open(a.out, "w").write("\n".join(o).rstrip() + "\n")
    print(f"{a.out}: {len(structs)} structs, {len(enums)} enums")


if __name__ == "__main__":
    main()
