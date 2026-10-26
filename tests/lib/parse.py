"""Parse showroom tracks, executable steps, and content checks."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

PAGES = Path("content/modules/ROOT/pages")
NAV = Path("content/modules/ROOT/nav.adoc")
IMAGE_ROOTS = (
    Path("content/modules/ROOT/images"),
    Path("content/modules/ROOT/assets/images"),
)

# Nav section title prefix -> (track id, index page)
SECTIONS = (
    ("101 OpenShift", "101", "basic-INDEX.adoc"),
    ("201 OpenShift", "201", "intermediate-INDEX.adoc"),
    ("301 OpenShift", "301", "advanced-INDEX.adoc"),
    ("Advanced Cluster Security", "acs", "acs-INDEX.adoc"),
    ("Software Supply Chain", "tssc", "tssc-INDEX.adoc"),
    ("OpenShift Virtualization", "virt", "virt-INDEX.adoc"),
)

SKIP_PAGES = {"index.adoc", "rhda-shift-left.adoc"}

XREF_RE = re.compile(r"xref:([^[\s]+)\[([^\]]*)\]")
SOURCE_RE = re.compile(r"^\[source,([^\]]*)\]\s*$")
CONSOLE_RE = re.compile(r"^\[\.console-output\]\s*$")
TITLE_RE = re.compile(r"^=\s+(.+?)\s*$")
IMAGE_RE = re.compile(r"image::([^\s\[]+)")
EXECUTE_RE = re.compile(r"""role=["']?execute["']?""")
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
TIP_RE = re.compile(r"^(TIP|NOTE):\s*(.*)$")

NS_RES = (
    re.compile(
        r"""\boc\s+new-project\s+(?:--\S+\s+)*["']?([A-Za-z0-9][A-Za-z0-9._-]*)"""
    ),
    re.compile(
        r"""\boc\s+create\s+(?:namespace|ns)\s+(?:--\S+\s+)*["']?([A-Za-z0-9][A-Za-z0-9._-]*)"""
    ),
)

INTERACTIVE_RE = re.compile(
    r"(?:^|[;&|`(]|&&|\|\|)\s*(?:oc\s+edit|vi|vim|nano|emacs|read)(?:\s|$)",
    re.MULTILINE,
)
TTY_RE = re.compile(
    r"\boc\s+(?:exec|rsh)\b[^\n]*\s(?:--tty|-[A-Za-z]*t[A-Za-z]*)(?:\s|$)",
    re.MULTILINE,
)
FOLLOW_RE = re.compile(
    r"\boc\s+(?:get|logs)\b[^\n]*(?:\s-w|\s--watch|\s-f|\s--follow)(?:\s|$)",
    re.MULTILINE,
)

MODULE_ID_RE = re.compile(r"^((?:101|201|301|acs|tssc|virt)-\d+)")

PROTECTED_EXACT = {"default", "openshift", "rhacs-operator"}
PROTECTED_PREFIXES = ("openshift-", "kube-")


@dataclass
class Step:
    index: int
    line: int
    command: str
    expected: str | None
    expected_kind: str  # console-output, sample, tip, none
    skipped: bool
    skip_reason: str
    section: str = ""
    preamble: str = ""


@dataclass
class Module:
    id: str
    title: str
    page: str
    path: Path
    track_id: str
    index_page: str
    steps: list[Step] = field(default_factory=list)
    namespaces: list[str] = field(default_factory=list)
    content_checks: list[dict] = field(default_factory=list)


@dataclass
class Track:
    id: str
    index_page: str
    modules: list[Module] = field(default_factory=list)


def module_id(page: str) -> str:
    stem = page[: -len(".adoc")] if page.endswith(".adoc") else page
    match = MODULE_ID_RE.match(stem)
    return match.group(1) if match else stem


def is_module_page(page: str) -> bool:
    if page in SKIP_PAGES or page.endswith("-INDEX.adoc"):
        return False
    if page.startswith("appendix-"):
        return False
    return page.endswith(".adoc")


def load_tracks(repo: Path) -> list[Track]:
    nav_text = (repo / NAV).read_text(encoding="utf-8")
    tracks: dict[str, Track] = {}
    current: Track | None = None
    for line in nav_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("."):
            title = stripped[1:]
            for prefix, track_id, index_page in SECTIONS:
                if title.startswith(prefix):
                    current = tracks.get(track_id)
                    if current is None:
                        current = Track(id=track_id, index_page=index_page)
                        tracks[track_id] = current
                    break
            continue
        if current is None:
            continue
        match = XREF_RE.search(stripped)
        if not match:
            continue
        page = match.group(1)
        if not is_module_page(page):
            continue
        label = match.group(2).strip()
        module = parse_module(repo, current.id, current.index_page, page, label, nav_text)
        current.modules.append(module)
    return [tracks[item[1]] for item in SECTIONS if item[1] in tracks]


def parse_module(
    repo: Path,
    track_id: str,
    index_page: str,
    page: str,
    label: str,
    nav_text: str,
) -> Module:
    path = repo / PAGES / page
    module = Module(
        id=module_id(page),
        title=label,
        page=page,
        path=path,
        track_id=track_id,
        index_page=index_page,
    )
    if not path.is_file():
        module.content_checks = [
            {
                "name": "page exists",
                "passed": False,
                "detail": f"missing {PAGES / page}",
            }
        ]
        return module
    text = path.read_text(encoding="utf-8")
    doc_title = _document_title(text)
    if doc_title:
        module.title = doc_title
    blocks = _parse_blocks(text)
    module.steps = _pair_steps(text, blocks)
    module.namespaces = _namespaces(module.steps)
    module.content_checks = _content_checks(repo, module, text, nav_text)
    return module


def _document_title(text: str) -> str:
    for line in text.splitlines():
        match = TITLE_RE.match(line)
        if match:
            return match.group(1).strip()
    return ""


@dataclass
class _Block:
    kind: str  # execute, console-output, sample
    line: int
    body: str
    end_line: int


def _parse_blocks(text: str) -> list[_Block]:
    lines = text.splitlines()
    blocks: list[_Block] = []
    index = 0
    while index < len(lines):
        console = False
        if CONSOLE_RE.match(lines[index].strip()):
            console = True
            index += 1
            while index < len(lines) and lines[index].strip() == "":
                index += 1
        if index >= len(lines):
            break
        source = SOURCE_RE.match(lines[index].strip())
        if not source:
            index += 1
            continue
        attrs = source.group(1)
        start = index + 1
        index += 1
        if index >= len(lines) or lines[index].strip() != "----":
            continue
        index += 1
        body: list[str] = []
        while index < len(lines) and lines[index].strip() != "----":
            body.append(lines[index])
            index += 1
        closed = index < len(lines) and lines[index].strip() == "----"
        if closed:
            index += 1
        execute = bool(EXECUTE_RE.search(attrs))
        if execute:
            kind = "execute"
        elif console:
            kind = "console-output"
        else:
            kind = "sample"
        blocks.append(
            _Block(
                kind=kind,
                line=start,
                body="\n".join(body).strip("\n"),
                end_line=index,
            )
        )
    return blocks


def _pair_steps(text: str, blocks: list[_Block]) -> list[Step]:
    lines = text.splitlines()
    steps: list[Step] = []
    number = 0
    for position, block in enumerate(blocks):
        if block.kind != "execute":
            continue
        number += 1
        expected, kind = _expected_for(lines, blocks, position)
        skipped, reason = _interactive(block.body)
        section, preamble = _lab_context(lines, block.line)
        steps.append(
            Step(
                index=number,
                line=block.line,
                command=block.body,
                expected=expected,
                expected_kind=kind,
                skipped=skipped,
                skip_reason=reason,
                section=section,
                preamble=preamble,
            )
        )
    return steps


def _expected_for(
    lines: list[str], blocks: list[_Block], position: int
) -> tuple[str | None, str]:
    window_end = len(lines)
    for nxt in blocks[position + 1 :]:
        if nxt.kind == "execute":
            window_end = nxt.line - 1
            break
        return nxt.body, nxt.kind
    start = blocks[position].end_line
    quotes = _tip_quotes(lines[start:window_end])
    if quotes:
        return "\n".join(quotes), "tip"
    return None, "none"


def _tip_quotes(lines: list[str]) -> list[str]:
    quotes: list[str] = []
    collecting = False
    paragraph: list[str] = []

    def flush() -> None:
        nonlocal paragraph
        if paragraph:
            quotes.extend(BACKTICK_RE.findall("\n".join(paragraph)))
        paragraph = []

    for line in lines:
        stripped = line.strip()
        if TIP_RE.match(stripped):
            flush()
            collecting = True
            paragraph = [stripped]
            continue
        if collecting:
            if stripped == "" or stripped.startswith("["):
                flush()
                collecting = False
                continue
            paragraph.append(stripped)
    flush()
    return [item.strip() for item in quotes if item.strip()]


def _lab_context(lines: list[str], source_line: int) -> tuple[str, str]:
    """Section title and the lab prose immediately above a command."""
    before = lines[: max(source_line - 1, 0)]
    section = ""
    section_at = -1
    for index, line in enumerate(before):
        stripped = line.strip()
        heading = re.match(r"^=+\s+(\S.*)$", stripped)
        title = re.match(r"^\.([A-Z].*)$", stripped)
        if heading:
            section = heading.group(1).strip()
            section_at = index
        elif title:
            section = title.group(1).strip()
            section_at = index
    prose: list[str] = []
    start = section_at + 1 if section_at >= 0 else 0
    for line in before[start:]:
        stripped = line.strip()
        if (
            not stripped
            or stripped in {"====", "----"}
            or stripped.startswith("[")
            or stripped.startswith("|")
            or stripped.startswith(".")
            or stripped.startswith("=")
        ):
            continue
        prose.append(stripped)
    return section, " ".join(prose)


def _interactive(command: str) -> tuple[bool, str]:
    if INTERACTIVE_RE.search(command) or TTY_RE.search(command):
        return True, "interactive command is not executed"
    if FOLLOW_RE.search(command):
        return True, "watch command is not executed"
    return False, ""


def namespaces_in_text(command: str) -> list[str]:
    found: list[str] = []
    for pattern in NS_RES:
        for name in pattern.findall(command):
            if name not in found:
                found.append(name)
    return found


def _namespaces(steps: list[Step]) -> list[str]:
    found: list[str] = []
    for step in steps:
        for name in namespaces_in_text(step.command):
            if name not in found:
                found.append(name)
    return found


def protected_namespace(name: str) -> bool:
    if name in PROTECTED_EXACT:
        return True
    return name.startswith(PROTECTED_PREFIXES)


def _content_checks(repo: Path, module: Module, text: str, nav_text: str) -> list[dict]:
    checks: list[dict] = []
    linked = f"xref:{module.page}[" in nav_text
    checks.append(
        {
            "name": "linked from nav",
            "passed": linked,
            "detail": "" if linked else f"{module.page} is not linked from nav.adoc",
        }
    )
    index_path = repo / PAGES / module.index_page
    if index_path.is_file():
        index_text = index_path.read_text(encoding="utf-8")
        in_index = f"xref:{module.page}[" in index_text
        detail = "" if in_index else f"{module.page} is not linked from {module.index_page}"
    else:
        in_index = False
        detail = f"missing index {module.index_page}"
    checks.append({"name": "linked from track index", "passed": in_index, "detail": detail})

    titled = bool(_document_title(text))
    checks.append(
        {
            "name": "title",
            "passed": titled,
            "detail": "" if titled else "page has no '= Title' line",
        }
    )

    fences = [line for line in text.splitlines() if line.strip() == "----"]
    closed = len(fences) % 2 == 0
    checks.append(
        {
            "name": "fences closed",
            "passed": closed,
            "detail": "" if closed else f"{len(fences)} '----' lines",
        }
    )

    missing_images = []
    for ref in IMAGE_RE.findall(text):
        if ref.startswith(("http://", "https://")):
            continue
        if not _image_exists(repo, ref):
            missing_images.append(ref)
    checks.append(
        {
            "name": "images resolve",
            "passed": not missing_images,
            "detail": ", ".join(missing_images),
        }
    )
    return checks


def _image_exists(repo: Path, ref: str) -> bool:
    for root in IMAGE_ROOTS:
        if (repo / root / ref).is_file():
            return True
    return False


def substitute(text: str, attrs: dict[str, str]) -> str:
    pattern = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")

    def repl(match: re.Match[str]) -> str:
        key = match.group(1)
        return attrs.get(key, match.group(0))

    current = text
    for _ in range(5):
        updated = pattern.sub(repl, current)
        if updated == current:
            break
        current = updated
    return current
