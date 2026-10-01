"""Syntax + semantic validation of DisasterZone_Data_generated.lua using the generator's Lua tokenizer/parser.
Accepts only the statement forms the generated file is supposed to use:
    local _, ns = ...
    ns.Data = ns.Data or {}
    ns.Data.<Name> = <table constructor>
"""
import os, sys, importlib.util
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(here, "gen_cdloot_data.py"))
gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)

path = os.path.join(here, "DisasterZone_Data_generated.lua")
text = open(path, encoding="utf-8").read()
toks, comments = gen.tokenize(text)   # raises on any unlexable character / unterminated string
p = gen.Parser(toks)

def expect_seq(seq):
    for kind, val in seq:
        p.expect(kind, val)

# statement 1
expect_seq([("name", "local"), ("name", "_"), ("op", ","), ("name", "ns"), ("op", "="), ("op", "...")])
# statement 2
expect_seq([("name", "ns"), ("op", "."), ("name", "Data"), ("op", "="), ("name", "ns"), ("op", "."), ("name", "Data"), ("name", "or"), ("op", "{"), ("op", "}")])
tables = {}
while p.peek() is not None:
    expect_seq([("name", "ns"), ("op", "."), ("name", "Data"), ("op", ".")])
    name = p.expect("name").val
    p.expect("op", "=")
    val = p.parse_expr()
    assert isinstance(val, gen.LuaTable), f"ns.Data.{name} is not a table constructor"
    assert name not in tables, f"duplicate ns.Data.{name}"
    tables[name] = val
assert p.i == len(toks), "trailing tokens"

# brace balance (belt and braces; the parser already guarantees it)
depth = 0
for t in toks:
    if t.kind == "op" and t.val in "{[(":
        depth += 1
    elif t.kind == "op" and t.val in "}])":
        depth -= 1
        assert depth >= 0, f"unbalanced close at line {t.line}"
assert depth == 0, "unbalanced braces"

# semantics
raids = tables["Raids"]
all_items = set()
nb = ni = 0
for r in raids.array:
    for k in ("key", "name", "phase", "size", "bosses"):
        assert r.get(k) is not None, f"raid missing {k}"
    keys = set()
    for b in r.get("bosses").array:
        bk = gen.resolve_text(b.get("key"))
        assert bk not in keys, f"duplicate boss key {bk} in {gen.resolve_text(r.get('key'))}"
        keys.add(bk)
        for k in ("key", "name", "npcIDs", "items"):
            assert b.get(k) is not None, f"boss {bk} missing {k}"
        for x in b.get("items").array:
            assert isinstance(x, int) and x > 0, f"bad item {x!r} in {bk}"
            all_items.add(x)
        for x in b.get("npcIDs").array:
            assert isinstance(x, int) and x > 0
        nb += 1
        ni += len(b.get("items").array)
tok = tables["Tokens"]
for k, v in tok.hash.items():
    assert isinstance(k, int) and k in all_items, f"token {k} not dropped by any boss"
    assert v.array and all(isinstance(x, int) for x in v.array)
for k, v in tables.get("Upgrades", gen.LuaTable(0)).hash.items():
    assert k in all_items and isinstance(v, int), f"upgrade base {k} not in any boss list"
print(f"OK: {os.path.basename(path)} parses; tables={list(tables)}; raids={len(raids.array)} bosses={nb} itemRows={ni} uniqueItems={len(all_items)} tokens={len(tok.hash)}")
