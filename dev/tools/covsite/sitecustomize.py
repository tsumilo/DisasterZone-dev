# tf_e/run_all.py puts this folder on PYTHONPATH, so every Python process of a test run (the suite and any child
# process it starts) records what it depended on (tools/testmap_rec.py). Does nothing without DZ_COVER.
import os

if os.environ.get("DZ_COVER"):
    try:
        import importlib.util
        import sys
        _p = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "testmap_rec.py")
        _spec = importlib.util.spec_from_file_location("testmap_rec", _p)
        _mod = importlib.util.module_from_spec(_spec)
        sys.modules["testmap_rec"] = _mod
        _spec.loader.exec_module(_mod)
        _mod.start()
    except Exception:  # noqa: BLE001 - never break a test process over coverage
        pass
