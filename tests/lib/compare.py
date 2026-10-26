"""Compare command output to the sample in a module."""

from __future__ import annotations

import re

DOMAIN_RE = re.compile(
    r"(?:[A-Za-z0-9.-]+\.)?apps\.cluster-[A-Za-z0-9-]+\.dyn\.redhatworkshops\.io"
    r"|cluster-[A-Za-z0-9-]+\.dyn\.redhatworkshops\.io"
)
TIME_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?"
    r"|\d{8}-\d{6}"
    r"|YYYYMMDD-HHMMSS"
)
UID_RE = re.compile(r"\b\d{7,}\b")
SHA_RE = re.compile(r"sha256:[0-9a-fA-F]{12,}")
ELLIPSIS_LINE_RE = re.compile(r"^\.{3,}$|^…$")


def normalize(text: str, live_domain: str = "") -> str:
    if live_domain:
        text = text.replace(live_domain, "{domain}")
    text = DOMAIN_RE.sub("{domain}", text)
    text = TIME_RE.sub("{time}", text)
    text = SHA_RE.sub("sha256:{sha}", text)
    text = UID_RE.sub("{uid}", text)
    return text


def missing_lines(expected: str, actual: str, live_domain: str = "") -> list[str]:
    """Return expected lines that do not appear in actual output.

    `...` lines and `YYYYMMDD-HHMMSS` placeholders are wildcards. Cluster
    hostnames, timestamps, large UIDs, and image digests are normalized
    before the comparison.
    """
    expected_text = normalize(expected, live_domain)
    actual_text = normalize(actual, live_domain)
    missing: list[str] = []
    for raw in expected_text.splitlines():
        line = raw.strip()
        if not line or ELLIPSIS_LINE_RE.match(line):
            continue
        if _line_in_output(line, actual_text):
            continue
        missing.append(line)
    return missing


def _line_in_output(line: str, actual_text: str) -> bool:
    if "..." not in line:
        return line in actual_text
    parts = [re.escape(part) for part in line.split("...")]
    return re.search(".*?".join(parts), actual_text) is not None
