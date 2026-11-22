#!/usr/bin/env python3
"""Odin foreign declarations for C functions, from clang's reading of the
headers (its AST as JSON).

  bind.py OUT.odin LIB NAMES.txt --headers '...' --cflags '...'

NAMES.txt lists the functions (one per line, # for comments). Struct
pointers become ^Name of an opaque Odin struct (declared here unless the
package already has it); C strings become cstring; integers keep their
width; callbacks and anything else become rawptr. abi/check.sh then checks
the result against the headers independently. The output is committed.
"""
import argparse, json, re, subprocess, sys, tempfile, os

INTS = {
    "char": "u8", "signed char": "i8", "unsigned char": "u8", "_Bool": "bool",
    "short": "i16", "unsigned short": "u16", "int": "i32", "unsigned int": "u32",
    "long": "int", "unsigned long": "uint", "long long": "i64", "unsigned long long": "u64",
    "float": "f32", "double": "f64",
}
# fixed-width names, mapped before their typedefs are followed
NAMED = {"guint64": "u64", "gint64": "i64", "uint64_t": "u64", "int64_t": "i64", "guint32": "u32",
         "gint32": "i32", "uint32_t": "u32", "int32_t": "i32", "guint16": "u16", "gint16": "i16",
         "guint8": "u8", "gint8": "i8", "gsize": "uint", "gssize": "int", "size_t": "uint"}
# typedef names kept as they are (the package declares them)
KEEP = {"gboolean", "GType"}
PREDECLARED = {"GObject", "GBytes", "GError", "GMainContext", "GPtrArray", "GAsyncResult", "GCancellable",
               "GVariant", "GObjectClass", "GTypeInfo", "GTypeQuery", "GValue"}

KEYWORDS = {"proc", "map", "context", "string", "type", "struct", "union", "enum", "in", "where", "when",
            "defer", "using", "package", "import", "foreign", "return", "for", "if", "else", "switch",
            "case", "cast", "matrix", "distinct", "dynamic", "transmute", "any", "rawptr", "typeid"}


def odin_type(qt, typedefs, opaques, depth=0):
    raw = qt
    t = re.sub(r"\b(const|volatile|restrict|__restrict)\b", "", qt).strip()
    t = re.sub(r"\s+", " ", t)
    if t in KEEP:
        return t
    if t in NAMED:
        return NAMED[t]
    if "(" in t:
        return "rawptr"  # a function pointer
    if t.endswith("*"):
        base = t[:-1].strip()
        if base.endswith("*"):
            return "rawptr"
        b = base
        if b in ("char", "gchar"):
            return "cstring"
        if b in ("void", "gpointer"):
            return "rawptr"
        if b.startswith("struct "):
            b = b[7:]
        # a typedef of a struct: its name
        name = b
        if name in typedefs:
            under = re.sub(r"\b(const|volatile)\b", "", typedefs[name]).strip()
            if under.startswith("struct ") or under.startswith("union "):
                opaques.add(name)
                return "^" + name
            ot = odin_type(typedefs[name], typedefs, opaques, depth + 1)
            return "rawptr" if ot.startswith("^") or ot in ("rawptr", "cstring") else "^" + ot
        if re.match(r"^_?[A-Z]\w*$", name):
            name = name.lstrip("_")
            opaques.add(name)
            return "^" + name
        return "rawptr"
    if t.startswith("enum "):
        return "i32"
    if t in INTS:
        return INTS[t]
    if t in typedefs and depth < 20:
        under = typedefs[t]
        if re.sub(r"^enum ", "", under.strip()) == t:
            return "i32"  # a typedef'd enum names itself
        if under.strip().startswith("enum ") or "enum" in under:
            return "i32"
        return odin_type(under, typedefs, opaques, depth + 1)
    if t == "void":
        return "void"
    raise ValueError(f"cannot map C type '{raw}'")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("lib")
    ap.add_argument("names")
    ap.add_argument("--headers", required=True)
    ap.add_argument("--cflags", default="")
    ap.add_argument("--package", default="iris")
    ap.add_argument("--have", default="", help="Odin types the package already declares")
    a = ap.parse_args()
    names = [l.split("#")[0].strip() for l in open(a.names)]
    names = [n for n in names if n]
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "all.c")
        open(src, "w").write("".join(f"#include <{h}>\n" for h in a.headers.split()))
        r = subprocess.run(["clang", "-fsyntax-only", "-Xclang", "-ast-dump=json", src] + a.cflags.split(),
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stderr[-3000:])
        ast = json.loads(r.stdout)
    typedefs, funcs = {}, {}
    for n in ast.get("inner", []):
        if n.get("kind") == "TypedefDecl":
            typedefs[n["name"]] = n["type"].get("desugaredQualType") or n["type"]["qualType"]
        if n.get("kind") == "FunctionDecl" and n.get("name") in names:
            funcs[n["name"]] = n
    missing = [x for x in names if x not in funcs]
    if missing:
        sys.exit("not in the headers: " + ", ".join(missing))
    opaques = set()
    lines = []
    for nm in names:
        f = funcs[nm]
        ftype = f["type"]["qualType"]
        ret = ftype.split("(", 1)[0].strip()
        ps = []
        used = set()
        for k, p in enumerate(x for x in f.get("inner", []) if x.get("kind") == "ParmVarDecl"):
            pn = p.get("name") or f"a{k}"
            if pn in KEYWORDS or pn in used:
                pn = pn + "_"
            used.add(pn)
            ps.append(f"{pn}: {odin_type(p['type']['qualType'], typedefs, opaques)}")
        if f.get("variadic"):
            sys.exit(f"{nm} takes C varargs: call another form")
        rt = odin_type(ret, typedefs, opaques)
        rets = "" if rt == "void" else f" -> {rt}"
        lines.append(f"\t{nm} :: proc({', '.join(ps)}){rets} ---")
    have = set(a.have.split()) | PREDECLARED
    ident = re.sub(r"\W", "_", a.lib).lower() + "_lib"
    out = [f"// Generated by tools/bind.py from the C headers ({os.path.basename(a.names)}). Do not edit:",
           "// list a function there and run tools/bind.sh.",
           f"package {a.package}", "", f'foreign import {ident} "system:{a.lib}"', ""]
    for o in sorted(opaques - have):
        out.append(f"{o} :: struct {{}}")
    out += ["", '@(default_calling_convention = "c")', f"foreign {ident} {{"] + lines + ["}", ""]
    open(a.out, "w").write("\n".join(out))
    print(f"{a.out}: {len(lines)} functions, {len(opaques - have)} opaque types")


if __name__ == "__main__":
    main()
