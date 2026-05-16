"""Wrapper entry point for fabric-retrieve.py console script."""
from pathlib import Path
import runpy


def main():
    runpy.run_path(
        str(Path(__file__).with_name("fabric-retrieve.py")),
        run_name="__main__",
    )
