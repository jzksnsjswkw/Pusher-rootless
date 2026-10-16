#!/usr/bin/env python3
"""Finds `.localized` strings in the Preferences sources that the Chinese table lacks.

A missing entry is invisible: `"Some text".localized` returns the English when
the lookup fails, so the only symptom is English appearing in a Chinese page. The
table is a few hundred entries long and is edited by hand, so the way to keep it
honest is to check it.

The awkward part is that a key is not always a literal. Swift allows

    ("first half " + "second half").localized

so the runtime key is the concatenation, and a check that looks at single literals
would report both halves as missing and miss the whole. This resolves the `+`
operators before looking anything up, and reads the keys out of the binary's own
table for the other side of the comparison.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Preferences"
TABLE = SOURCES / "Resources" / "zh-Hans.lproj" / "Localizable.strings"

# `.localized` is also applied to things that are already keys computed at
# runtime, which this cannot resolve; they are collected and reported separately
# rather than counted as missing.
DYNAMIC = re.compile(r'(\w+\(|\)\[|\.\w+\(|^\s*\))', re.M)


def find_receiver(text: str, dot: int) -> str | None:
    """The expression `.localized` is applied to, `dot` being its period."""
    i = dot
    depth = 0
    in_string = False
    while i > 0:
        ch = text[i - 1]
        # Characters inside a literal are text, not syntax. Without this, the
        # comma in `"Separated by bars, like this".localized` reads as the
        # boundary between arguments and the scan stops in the middle of the
        # string — which is how that key went unreported while being absent from
        # the table.
        if ch == '"' and not _escaped(text, i - 1):
            in_string = not in_string
            i -= 1
            continue
        if in_string:
            i -= 1
            continue
        if ch in ")]":
            depth += 1
        elif ch in "([":
            if depth == 0:
                i -= 1
                break
            depth -= 1
        # Boundaries. `[` and `,` matter for `["A".localized, "B".localized]`, where
        # scanning past the comma would take both. The operators are here because
        # `.localized` binds tighter than `+`: in `"- " + "…".localized` the key is
        # the second string alone, and stopping at the `+` is what keeps the list
        # marker out of it.
        elif depth == 0 and ch in "\n;,?:=[+-*/":
            break
        i -= 1
    expr = text[i:dot].strip()

    # `foo(("a" + "b").localized)`: the scan stopped at the argument list's own
    # parenthesis, so the expression it returns is `("a" + "b")` — which is the
    # key. But `foo(("a" + key).localized)` and `foo("a".localized)` look the
    # same from here, so balanced parentheses are stripped only by `resolve`,
    # which then checks whether what remains is nothing but literals.
    return expr


def _escaped(text: str, index: int) -> bool:
    """Whether the character at `index` is preceded by an odd run of backslashes."""
    backslashes = 0
    i = index - 1
    while i >= 0 and text[i] == "\\":
        backslashes += 1
        i -= 1
    return backslashes % 2 == 1


def resolve(expr: str) -> str | None:
    """The concatenation of `expr`'s string literals, or None if it has more.

    Swift writes a long localized string as a paren-wrapped concatenation, and
    the parens nest once per `+` because each one is a binary expression:

        .text(("first part " + "second part "  + "third").localized)

    So the parentheses are stripped repeatedly, and what remains is checked to be
    nothing but string literals and `+`. Interpolations and ternaries come back as
    None and are reported separately rather than counted as missing.
    """
    expr = expr.strip()

    def encloses(text: str) -> bool:
        """Whether the outer parentheses wrap the whole expression."""
        if not (text.startswith("(") and text.endswith(")")):
            return False
        depth = 0
        for index, ch in enumerate(text[:-1]):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return False  # closed before the end
        return depth == 1

    while encloses(expr):
        expr = expr[1:-1].strip()

    # A ternary whose branches are literals — `(flag ? "A" : "B").localized` — has
    # two keys, and both are looked up. Reported as the pair so neither is missed.
    ternary = re.match(r'^\(?\s*[^?]+?\s*\?\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"\s*\)?$', expr)
    if ternary:
        return ternary.group(1) + "\u0000" + ternary.group(2)

    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', expr)
    if not literals:
        return None
    # Argument labels and parentheses are not values: `String(format: "…")`
    # leaves `format:` behind, and it says nothing about whether the key is
    # static. An identifier, a call or a ternary does, and those still fail here.
    remainder = (
        re.sub(r'"(?:[^"\\]|\\.)*"', "", expr)
        .replace("+", "")
        .replace("(", "")
        .replace(")", "")
    )
    remainder = re.sub(r"\b[A-Za-z_][A-Za-z0-9_]*\s*:", "", remainder)
    if remainder.strip():
        return None
    return "".join(literals)


def swift_keys() -> tuple[set[str], list[str]]:
    used: set[str] = set()
    dynamic: list[str] = []
    for path in sorted(SOURCES.rglob("*.swift")):
        text = path.read_text()
        for match in re.finditer(r"\.localized\b", text):
            expr = find_receiver(text, match.start())
            if expr is None:
                continue
            key = resolve(expr)
            if key is None:
                dynamic.append(f"{path.relative_to(ROOT)}: {expr[:60]}")
            else:
                used.update(key.split("\u0000"))
    return used, dynamic


def table_keys() -> set[str]:
    text = TABLE.read_text()
    return set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M))


def main() -> int:
    if not TABLE.exists():
        print(f"no table at {TABLE}", file=sys.stderr)
        return 1

    used, dynamic = swift_keys()
    have = table_keys()
    missing = sorted(k for k in used if k not in have)

    print(f"used={len(used)}  have={len(have)}  missing={len(missing)}")
    if dynamic:
        print(f"not resolvable to a literal ({len(dynamic)}):")
        for item in dynamic:
            print(f"  {item}")
    for key in missing:
        print(f"  MISSING {key!r}")

    # No "unused entries" report: the keys are also written where a `String(format:)`
    # or a comparison reads them, which this does not resolve, so a key that looks
    # unused may be in constant use through another call shape. A wrong list is
    # worse than none — it invites deleting entries that are live.

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
