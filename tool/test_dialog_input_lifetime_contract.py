#!/usr/bin/env python3
"""Keep route-local text input from outliving manually-disposed controllers."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "apps/app/lib"
local_controller = re.compile(
    r"^(?P<indent>[ \t]{4,})"
    r"(?:(?:late\s+)?final|var|TextEditingController)\b"
    r"[^\n=]*=\s*TextEditingController\s*\(",
    re.MULTILINE,
)

probe = """
  final TextEditingController stateField = TextEditingController();
    final inferred = TextEditingController();
    late final typed = TextEditingController();
    var mutable = TextEditingController();
    TextEditingController explicit = TextEditingController();
"""
probe_matches = list(local_controller.finditer(probe))
if len(probe_matches) != 4:
    raise SystemExit(
        "dialog input lifetime detector self-check failed: "
        f"expected 4 local declarations, got {len(probe_matches)}"
    )

violations: list[str] = []
for path in sorted(LIB.glob("*.dart")):
    body = path.read_text(encoding="utf-8")
    for match in local_controller.finditer(body):
        line = body.count("\n", 0, match.start()) + 1
        violations.append(f"{path.relative_to(ROOT)}:{line}")

if violations:
    raise SystemExit(
        "route-local TextEditingController requires an explicit State lifecycle; "
        "prefer TextFormField(initialValue/onChanged) for dialog-local input: "
        + ", ".join(violations)
    )

print("Dialog input controller lifetime contract: OK")
