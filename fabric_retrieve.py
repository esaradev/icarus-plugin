"""Console entry point — delegates to fabric-retrieve.py if available."""
import runpy
import sys
from pathlib import Path


def main():
    script = Path(__file__).with_name("fabric-retrieve.py")
    if script.exists():
        runpy.run_path(str(script), run_name="__main__")
    else:
        print(
            "fabric-retrieve.py not found next to fabric_retrieve.py. "
            "This console script requires a source/editable install.",
            file=sys.stderr,
        )
        sys.exit(1)
