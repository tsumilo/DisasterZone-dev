"""Runs a suite's cases each in a forked process, building shared set-up once (POSIX only: the WSL runner, tools/wsl/).

Most of a suite's time was each case building the same world again (`r = setup()`: seven clients booting, a sync)
before a few hundred milliseconds of its own. Here the runner reads each case's source and takes its leading simple
statements (assignments and calls, up to the first `if` / `for` / `with` / `assert` / `def` ...) as its set-up.
Cases whose set-up is the same code form a group: one forked process (the zygote) runs the shared statements once,
then forks again for every case of the group, and the case goes on from there with the names the set-up bound.
Every case runs in a process of its own, forked from a parent that ran no case, so nothing one case does reaches the
next (the sequential runner shared module state between cases).

Not split (run whole, each in a fresh fork of the parent): a case that closes over outer names, has arguments,
declares global / nonlocal, reads a local before the set-up binds it, uses a lambda in its set-up, or whose set-up
nobody else shares. A group whose set-up raises runs its cases whole, so the error shows in each case as before.

    results = forkrun.run_cases([(name, fn), ...], one)   # one(name, fn) runs a case, prints, returns True on pass

DZ_FORK=0 (or no os.fork: Windows) runs the cases one after another in this process, as before.
"""
import ast
import inspect
import json
import os
import sys
import textwrap
import types

ON = hasattr(os, "fork") and os.environ.get("DZ_FORK", "1") != "0"


# -- splitting a case ------------------------------------------------------------------------------------------------
class _Plan:
    def __init__(self, fn, fdef, stmts, filename):
        self.fn, self.fdef, self.stmts, self.filename = fn, fdef, stmts, filename
        self.keys = [ast.dump(s) for s in stmts]   # the leading simple statements, as code


def _bound_names(stmts):
    out = []
    for st in stmts:
        for node in ast.walk(st):
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store) and node.id not in out:
                out.append(node.id)
    return out


def _simple(st):
    if not isinstance(st, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.Expr)):
        return False
    return not any(isinstance(n, (ast.Lambda, ast.Yield, ast.YieldFrom, ast.Await)) for n in ast.walk(st))


def _plan(fn):
    code = getattr(fn, "__code__", None)
    if code is None or code.co_freevars or code.co_argcount or code.co_kwonlyargcount or \
            code.co_flags & (inspect.CO_GENERATOR | inspect.CO_COROUTINE | inspect.CO_VARARGS | inspect.CO_VARKEYWORDS):
        return None
    try:
        lines, start = inspect.getsourcelines(fn)
        filename = inspect.getsourcefile(fn)
        tree = ast.parse(textwrap.dedent("".join(lines)))
    except (OSError, TypeError, SyntaxError):
        return None
    if not tree.body or not isinstance(tree.body[0], ast.FunctionDef) or tree.body[0].name != fn.__name__:
        return None
    fdef = tree.body[0]
    ast.increment_lineno(fdef, start - 1)
    if any(isinstance(n, (ast.Global, ast.Nonlocal)) for n in ast.walk(fdef)):
        return None
    body = fdef.body
    i = 1 if (body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant)
              and isinstance(body[0].value.value, str)) else 0
    stmts = []
    while i < len(body) - 1 and _simple(body[i]):    # (the last statement stays: something must remain to run)
        stmts.append(body[i])
        i += 1
    if not stmts:
        return None
    return _Plan(fn, fdef, stmts, filename)


def _reads_unbound(plan, n):
    """Does the first n statements' code read a local of the case it has not bound yet (UnboundLocalError there)?"""
    local = set(plan.fn.__code__.co_varnames) | set(plan.fn.__code__.co_cellvars)
    bound = set()
    for st in plan.stmts[:n]:
        for node in ast.walk(st):
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and node.id in local \
                    and node.id not in bound:
                return True
        if isinstance(st, ast.AugAssign) and isinstance(st.target, ast.Name) and st.target.id not in bound:
            return True
        bound.update(_bound_names([st]))
    return False


def _compile(plan, n):
    """(prefix(), suffix(env)) for a case whose first n statements are its set-up."""
    head, rest = plan.stmts[:n], plan.fdef.body[plan.fdef.body.index(plan.stmts[n - 1]) + 1:]
    names = _bound_names(head)
    line = rest[0].lineno
    ret = ast.Return(ast.Dict([ast.Constant(k) for k in names], [ast.Name(k, ast.Load()) for k in names]))
    pre = ast.FunctionDef("%s__setup" % plan.fn.__name__,ast.arguments([], [], None, [], [], None, []),
                          head + [ret], [], None, None, [])
    pull = [ast.Assign([ast.Name(k, ast.Store())], ast.Subscript(ast.Name("__dz_env__", ast.Load()),
                                                                  ast.Constant(k), ast.Load()))
            for k in names]
    suf = ast.FunctionDef(plan.fn.__name__, ast.arguments([], [ast.arg("__dz_env__")], None, [], [], None, []),
                          pull + rest, [], None, None, [])
    for node in (ret, pre, *pull, suf):
        node.lineno = node.end_lineno = line
        node.col_offset = node.end_col_offset = 0
    mod = ast.fix_missing_locations(ast.Module([pre, suf], []))
    code = compile(mod, plan.filename, "exec")
    fns = [types.FunctionType(c, plan.fn.__globals__) for c in code.co_consts if isinstance(c, types.CodeType)]
    return fns[0], fns[1]


# -- processes -------------------------------------------------------------------------------------------------------
def _flush():
    for s in (sys.stdout, sys.stderr):
        try:
            s.flush()
        except Exception:  # noqa: BLE001
            pass


def _exit(code):
    _flush()
    rec = sys.modules.get("testmap_rec")   # this process's dependencies (it ran the case): written as at exit
    if rec is not None and getattr(rec, "_started", False):
        try:
            rec._write()
        except Exception:  # noqa: BLE001
            pass
    os._exit(code)


def _fork_case(name, thunk, one):
    """Runs one(name, thunk) in a child; True when it passed."""
    _flush()
    pid = os.fork()
    if pid == 0:
        try:
            ok = one(name, thunk)
        except BaseException:  # noqa: BLE001 - the runner's own reporting failed
            import traceback
            traceback.print_exc()
            ok = False
        _exit(0 if ok else 1)
    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status) == 0
    print("FAIL %s (the case's process died: signal %d)" % (name, os.WTERMSIG(status)))
    return False


def _whole(fn):
    def run():
        return fn()
    run.__name__ = fn.__name__
    return run


def _run_group(members, n, one):
    """Cases sharing their first n statements: one zygote runs them, a fork per case. {name: passed} or None when
    the set-up itself failed (the caller runs the cases whole)."""
    _flush()
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        out = {}
        try:
            parts = [(name, _compile(plan, n)) for name, plan in members]
            env = parts[0][1][0]()          # the shared set-up, once
        except BaseException:  # noqa: BLE001
            env = None
        if env is not None:
            for name, (_, suffix) in parts:
                def thunk(suffix=suffix):
                    return suffix(env)
                thunk.__name__ = name
                out[name] = _fork_case(name, thunk, one)
        with os.fdopen(w, "w") as fh:
            json.dump(out if env is not None else None, fh)
        os._exit(0)                          # (the zygote's own coverage reached every case it forked)
    os.close(w)
    with os.fdopen(r) as fh:
        data = fh.read()
    os.waitpid(pid, 0)
    try:
        return json.loads(data) if data else None
    except ValueError:
        return None


def run_cases(cases, one):
    """cases: [(name, fn)]; one(name, fn) runs fn, prints PASS/FAIL and returns True when it passed.
    Returns [(name, passed)] in the order the cases ran (a group's cases run together)."""
    if not ON:
        return [(name, one(name, fn)) for name, fn in cases]
    harness = sys.modules.get("harness")
    if harness is not None and len(cases) > 1:
        try:
            harness.warm()           # every fork starts with the addon's bytecode read
        except Exception:  # noqa: BLE001 - only a cache
            pass
    plans = [(name, fn, _plan(fn)) for name, fn in cases]
    # group by the first set-up statement; a group shares its longest common run of set-up statements
    groups, order = {}, []
    for name, fn, plan in plans:
        k = plan.keys[0] if plan else None
        if k is None or k not in groups:
            order.append(k if k is not None else ("whole", name))
        groups.setdefault(k if k is not None else ("whole", name), []).append((name, fn, plan))
    results = []
    for k in order:
        members = groups[k]
        if isinstance(k, tuple) or len(members) < 2:
            results += [(name, _fork_case(name, _whole(fn), one)) for name, fn, _ in members]
            continue
        n = min(len(p.keys) for _, _, p in members)
        while n > 1 and len({tuple(p.keys[:n]) for _, _, p in members}) > 1:
            n -= 1
        ok_members = [(name, p) for name, _, p in members if not _reads_unbound(p, n)]
        whole = [(name, fn) for name, fn, p in members if _reads_unbound(p, n)]
        got = _run_group(ok_members, n, one) if len(ok_members) > 1 else None
        if got is None:
            whole = [(name, fn) for name, fn, _ in members]
        else:
            results += [(name, got.get(name, False)) for name, _ in ok_members]
        results += [(name, _fork_case(name, _whole(fn), one)) for name, fn in whole]
    return results
