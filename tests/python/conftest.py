import sys
from pathlib import Path

# The scripts' shared modules, importable by the tests.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
sys.dont_write_bytecode = True
