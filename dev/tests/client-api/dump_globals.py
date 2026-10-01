import sys, os, json, collections
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))
import luabc, check
ROOT = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
files = [f for f in check.iter_lua_files(ROOT)]
known = check.load_known()
kg = known.get("globals", {})
reads = collections.defaultdict(list)
fields = collections.defaultdict(list)
own = set()
for p in files:
    r = os.path.relpath(p, ROOT)
    if r.startswith("Libs"): continue
    src = open(p, "rb").read()
    bc, err = luabc.compile_chunk(src, "@" + r)
    acc = luabc.analyze(luabc.parse_bytecode(bc))
    for a in acc:
        if a.kind == "set": own.add(a.name)
        if a.kind == "get":
            reads[a.name].append("%s:%d" % (r, a.line))
            if a.field is not None:
                fields["%s.%s" % (a.name, a.field)].append("%s:%d" % (r, a.line))
        if a.kind == "field":
            fields["%s.%s" % (a.name, a.field)].append("%s:%d" % (r, a.line))
out = []
for n in sorted(reads):
    if n in check.LUA_STDLIB or n in own: continue
    out.append("%-40s %4d known=%-5s %s" % (n, len(reads[n]), kg.get(n, 0), " ".join(reads[n][:4])))
print("\n".join(out))
print("=== FIELDS")
for n in sorted(fields):
    ns = n.split(".")[0]
    if ns in check.STD_FIELDS: continue
    print("%-50s %4d %s" % (n, len(fields[n]), " ".join(fields[n][:3])))
