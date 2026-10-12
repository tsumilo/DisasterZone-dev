"""Lua 5.1 compile + bytecode analysis (the classic `luac -l | grep ETGLOBAL` approach, in Python).

compile_chunk(src_bytes, chunkname) -> (bytecode_bytes, None) or (None, "file:line: message")
parse_bytecode(bytecode) -> Proto tree
analyze(proto) -> list of Access(kind, name, line, field)

kind is one of:
  'get'     GETGLOBAL name                         (field = first constant key indexed on it, if any)
  'set'     SETGLOBAL name
  'get_G'   _G.name / _G["name"] read              (constant key only)
  'set_G'   _G.name = ... / _G["name"] = ...        (constant key only)
"""
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SITE = os.path.join(os.path.dirname(_HERE), "luaenv", "Lib", "site-packages")
if os.path.isdir(_SITE) and _SITE not in sys.path:
    sys.path.insert(0, _SITE)

from lupa import lua51  # noqa: E402

# Lua 5.1 opcodes (lopcodes.h)
OPNAMES = ("MOVE LOADK LOADBOOL LOADNIL GETUPVAL GETGLOBAL GETTABLE SETGLOBAL SETUPVAL SETTABLE "
           "NEWTABLE SELF ADD SUB MUL DIV MOD POW UNM NOT LEN CONCAT JMP EQ LT LE TEST TESTSET CALL "
           "TAILCALL RETURN FORLOOP FORPREP TFORLOOP SETLIST CLOSE CLOSURE VARARG").split()
OP = {n: i for i, n in enumerate(OPNAMES)}
GETGLOBAL, SETGLOBAL, GETTABLE, SETTABLE, SELF = OP["GETGLOBAL"], OP["SETGLOBAL"], OP["GETTABLE"], OP["SETTABLE"], OP["SELF"]
CLOSURE, RETURN = OP["CLOSURE"], OP["RETURN"]
# opcodes that write R(A) (used to stop the _G.x = ... forward scan)
_WRITES_A = {OP[n] for n in ("MOVE LOADK LOADBOOL LOADNIL GETUPVAL GETGLOBAL GETTABLE NEWTABLE SELF ADD SUB "
                             "MUL DIV MOD POW UNM NOT LEN CONCAT CLOSURE VARARG TESTSET").split()}
_STOP = {OP[n] for n in "JMP RETURN TAILCALL FORLOOP FORPREP TFORLOOP".split()}


class _Compiler:
    _rt = None
    _fn = None

    @classmethod
    def get(cls):
        if cls._fn is None:
            cls._rt = lua51.LuaRuntime(unpack_returned_tuples=True, encoding=None,
                                       register_eval=False, register_builtins=False)
            cls._fn = cls._rt.execute(b"""
                return function(src, name)
                    local f, err = loadstring(src, name)
                    if not f then return false, err end
                    return true, string.dump(f)
                end""")
        return cls._fn


def compile_chunk(src, chunkname):
    """Compile Lua 5.1 source. Returns (bytecode, None) or (None, errmsg)."""
    if isinstance(src, str):
        src = src.encode("utf-8")
    if src.startswith(b"\xef\xbb\xbf"):
        src = src[3:]
    if isinstance(chunkname, str):
        chunkname = chunkname.encode("utf-8")
    ok, res = _Compiler.get()(src, chunkname)
    if not ok:
        return None, (res.decode("utf-8", "replace") if isinstance(res, bytes) else str(res))
    return res, None


class Proto:
    __slots__ = ("source", "linedefined", "lastlinedefined", "nups", "numparams", "is_vararg",
                 "maxstack", "code", "consts", "protos", "lineinfo", "locvars", "upvalues")


class _Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0
        if data[:4] != b"\x1bLua":
            raise ValueError("not a Lua chunk")
        if data[4] != 0x51:
            raise ValueError("not Lua 5.1 bytecode (version byte 0x%02x)" % data[4])
        self.fmt, endian, self.sint, self.ssize, self.sinstr, self.snum, self.integral = data[5:12]
        self.e = "<" if endian == 1 else ">"
        self.p = 12
        ints = {1: "b", 2: "h", 4: "i", 8: "q"}
        uints = {1: "B", 2: "H", 4: "I", 8: "Q"}
        self._int = struct.Struct(self.e + ints[self.sint])
        self._size = struct.Struct(self.e + uints[self.ssize])
        self._ins = struct.Struct(self.e + uints[self.sinstr])
        if self.integral:
            self._num = struct.Struct(self.e + ints[self.snum])
        else:
            self._num = struct.Struct(self.e + {4: "f", 8: "d"}[self.snum])

    def _unpack(self, st):
        v = st.unpack_from(self.d, self.p)[0]
        self.p += st.size
        return v

    def byte(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def int(self):
        return self._unpack(self._int)

    def size(self):
        return self._unpack(self._size)

    def string(self):
        n = self.size()
        if n == 0:
            return None
        s = self.d[self.p:self.p + n - 1]  # drop trailing NUL
        self.p += n
        return s

    def function(self, parent_source=None):
        f = Proto()
        src = self.string()
        f.source = src if src is not None else parent_source
        f.linedefined = self.int()
        f.lastlinedefined = self.int()
        f.nups, f.numparams, f.is_vararg, f.maxstack = self.byte(), self.byte(), self.byte(), self.byte()
        n = self.int()
        st = self._ins
        f.code = list(struct.unpack_from(self.e + st.format[1:] * n, self.d, self.p)) if n else []
        self.p += st.size * n
        n = self.int()
        consts = []
        for _ in range(n):
            t = self.byte()
            if t == 0:
                consts.append(None)
            elif t == 1:
                consts.append(bool(self.byte()))
            elif t == 3:
                consts.append(self._unpack(self._num))
            elif t == 4:
                consts.append(self.string())
            else:
                raise ValueError("bad constant type %d" % t)
        f.consts = consts
        n = self.int()
        f.protos = [self.function(f.source) for _ in range(n)]
        n = self.int()
        f.lineinfo = [self.int() for _ in range(n)]
        n = self.int()
        f.locvars = []
        for _ in range(n):
            name = self.string()
            f.locvars.append((name, self.int(), self.int()))
        n = self.int()
        f.upvalues = [self.string() for _ in range(n)]
        return f


def parse_bytecode(data):
    return _Reader(data).function()


def _dec(b):
    if b is None:
        return None
    return b.decode("utf-8", "replace") if isinstance(b, (bytes, bytearray)) else str(b)


class Access:
    __slots__ = ("kind", "name", "line", "field", "fline")

    def __init__(self, kind, name, line, field=None, fline=None):
        self.kind, self.name, self.line, self.field, self.fline = kind, name, line, field, fline or line

    def __repr__(self):
        return "Access(%s,%s,%s,%s)" % (self.kind, self.name, self.line, self.field)


def _rk_const(f, x):
    """If RK operand x is a string constant, return it decoded."""
    if x >= 256:
        k = f.consts[x - 256]
        if isinstance(k, (bytes, bytearray)):
            return _dec(k)
    return None


NAMESPACE_EXTRA = {"Enum", "Settings", "MenuUtil", "ScrollUtil", "EventUtil", "ChatFrameUtil", "TableUtil",
                   "EventRegistry", "Item", "Spell", "TooltipUtil", "SettingsPanel", "MenuResponse", "ScrollBoxConstants",
                   "string", "table", "math", "os", "bit", "coroutine"}


def is_namespace_name(name):
    return bool(name) and (name.startswith("C_") or name in NAMESPACE_EXTRA)


def _local_name(f, reg, pc):
    """Name of the local variable living in register `reg` at `pc` (Lua 5.1 allocates active locals
    to registers in declaration order), or None."""
    i = 0
    for name, startpc, endpc in f.locvars:
        if startpc <= pc < endpc:
            if i == reg:
                return _dec(name)
            i += 1
    return None


def analyze(proto):
    """Walk all nested protos; return list of Access.
    kinds: get / set / get_G / set_G (see module doc) and
           field: `ns.key` read through a local/upvalue alias named like an API namespace
                  (`local C_Timer = C_Timer ... C_Timer.After`); name=ns, field=key."""
    out = []
    stack = [proto]
    while stack:
        f = stack.pop()
        stack.extend(f.protos)
        code = f.code
        n = len(code)
        li = f.lineinfo
        ups = f.upvalues
        for pc in range(n):
            ins = code[pc]
            op = ins & 0x3F
            line = li[pc] if pc < len(li) else 0
            if op == GETTABLE or op == SELF:
                # alias access: B is a local or was just loaded from an upvalue named like a namespace
                b = (ins >> 23) & 0x1FF
                if b >= 256:
                    continue
                key = _rk_const(f, (ins >> 14) & 0x1FF)
                if key is None:
                    continue
                src = None
                if pc > 0:
                    pv = code[pc - 1]
                    pop = pv & 0x3F
                    if ((pv >> 6) & 0xFF) == b:
                        if pop == GETGLOBAL:
                            continue  # handled by the GETGLOBAL branch
                        if pop == OP["GETUPVAL"]:
                            ui = (pv >> 23) & 0x1FF
                            if ui < len(ups):
                                src = _dec(ups[ui])
                if src is None:
                    src = _local_name(f, b, pc)
                if is_namespace_name(src):
                    out.append(Access("field", src, line, key))
                continue
            if op != GETGLOBAL and op != SETGLOBAL:
                continue
            a = (ins >> 6) & 0xFF
            name = _dec(f.consts[ins >> 14])
            if op == SETGLOBAL:
                out.append(Access("set", name, line))
                continue
            field = None
            nx = code[pc + 1] if pc + 1 < n else 0
            if pc + 1 < n:
                nop = nx & 0x3F
                if nop in (GETTABLE, SELF) and ((nx >> 23) & 0x1FF) == a:
                    field = _rk_const(f, (nx >> 14) & 0x1FF)
            if name == "_G":
                # _G.X read (GETTABLE right after) or _G.X = v (SETTABLE on the same register later)
                if field is not None and (nx & 0x3F) == GETTABLE:
                    sub = None
                    if pc + 2 < n:
                        nn = code[pc + 2]
                        if (nn & 0x3F) in (GETTABLE, SELF) and ((nn >> 23) & 0x1FF) == ((nx >> 6) & 0xFF):
                            sub = _rk_const(f, (nn >> 14) & 0x1FF)
                    out.append(Access("get_G", field, line, sub))
                else:
                    for q in range(pc + 1, min(n, pc + 60)):
                        qi = code[q]
                        qop = qi & 0x3F
                        qa = (qi >> 6) & 0xFF
                        if qop == SETTABLE and qa == a:
                            key = _rk_const(f, (qi >> 23) & 0x1FF)
                            if key is not None:
                                out.append(Access("set_G", key, li[q] if q < len(li) else line))
                            break
                        if qop in _STOP or (qop in _WRITES_A and qa == a) or (qop == OP["CALL"] and qa <= a):
                            break
                out.append(Access("get", name, line, None))
            else:
                out.append(Access("get", name, line, field, li[pc + 1] if field is not None and pc + 1 < len(li) else None))
    return out


def count_empty_global_functions(proto):
    """Heuristic for IDE/lint stub files: `function Foo() end` at top level (CLOSURE of a proto whose
    code is a single RETURN, followed by SETGLOBAL)."""
    cnt = 0
    stack = [proto]
    while stack:
        f = stack.pop()
        stack.extend(f.protos)
        code = f.code
        for pc in range(len(code) - 1):
            ins = code[pc]
            if ins & 0x3F == CLOSURE and code[pc + 1] & 0x3F == SETGLOBAL:
                sub = f.protos[ins >> 14]
                if len(sub.code) <= 1:
                    cnt += 1
    return cnt


def max_active_locals(f):
    """(count, startpc) of the most locals active at once in one function (its own registers only).
    Lua 5.1 refuses to compile a function with more than 200 (LUAI_MAXVARS); the debug info lists every
    local with the pc range it lives in, parameters and for-loop control variables included."""
    best, at = 0, 0
    last = len(f.code) - 1           # a local whose range ends at the final RETURN lives to the end of the function
    ends = [e if e < last else 1 << 30 for _, _, e in f.locvars]
    lv = f.locvars
    for i, (_, start, _end) in enumerate(lv):
        n = 1
        for j in range(i):
            # alive at i's declaration, or declared by the same statement (same range, e.g. `do local a, b end`)
            if ends[j] > start or (lv[j][1] == start and ends[j] == ends[i]):
                n += 1
        if n > best:
            best, at = n, start
    return best, at


def iter_protos(proto):
    """Every function in a chunk, the main chunk first (depth first, in source order)."""
    stack = [proto]
    while stack:
        f = stack.pop()
        yield f
        stack.extend(reversed(f.protos))


def limits(proto):
    """Lua 5.1 size limits of one compiled chunk. Returns a list of dicts, one per function:
    {main, line (linedefined; 0 = main chunk), last, locals, locals_line, upvalues}. locals_line is the line where
    the most locals are active (the declaration that reaches the peak)."""
    out = []
    for f in iter_protos(proto):
        n, pc = max_active_locals(f)
        li = f.lineinfo
        out.append({"main": f is proto, "line": f.linedefined, "last": f.lastlinedefined, "locals": n,
                    "locals_line": li[pc] if pc < len(li) else f.linedefined, "upvalues": f.nups})
    return out


def analyze_source(src, chunkname):
    """Compile + analyze. Returns (accesses, None) or (None, errmsg)."""
    bc, err = compile_chunk(src, chunkname)
    if bc is None:
        return None, err
    return analyze(parse_bytecode(bc)), None


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path, "rb") as fh:
            acc, err = analyze_source(fh.read(), "@" + path)
        if err:
            print(err)
            continue
        for a in sorted(acc, key=lambda x: (x.line, x.kind, x.name)):
            print("%s:%d: %s %s%s" % (path, a.line, a.kind, a.name, ("." + a.field) if a.field else ""))
