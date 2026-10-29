#!/usr/bin/env python3
"""Validates .loomo files against Schemas/loomo.schema.json.

    python3 scripts/check-schema.py file.loomo [more files…]      (needs: pip install jsonschema)
"""
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

schema = json.loads((pathlib.Path(__file__).parent.parent / "Schemas" / "loomo.schema.json").read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)

failed = False
for path in sys.argv[1:]:
    errors = sorted(validator.iter_errors(json.loads(pathlib.Path(path).read_text())), key=lambda e: list(e.path))
    for e in errors:
        print(f"{path}: {'/'.join(map(str, e.path)) or '(root)'}: {e.message}")
    print(f"{path}: {'OK' if not errors else f'{len(errors)} problem(s)'}")
    failed |= bool(errors)
sys.exit(1 if failed else 0)
