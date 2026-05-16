"""Console entry point — delegates to export-training.py if available."""
import runpy
import sys
from pathlib import Path


def main():
    script = Path(__file__).with_name("export-training.py")
    if script.exists():
        runpy.run_path(str(script), run_name="__main__")
    else:
        print(
            "export-training.py not found next to export_training.py. "
            "This console script requires a source/editable install.",
            file=sys.stderr,
        )
        sys.exit(1)
