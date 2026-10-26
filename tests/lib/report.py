"""Write markdown and JSON reports for a test run."""

from __future__ import annotations

import copy
import json
from pathlib import Path

OUTPUT_LIMIT = 4000
JSON_OUTPUT_LIMIT = 8000


def write_report(report_dir: Path, payload: dict) -> None:
    report_dir.mkdir(parents=True, exist_ok=True)
    stored = copy.deepcopy(payload)
    for track in stored["tracks"]:
        for module in track["modules"]:
            for step in module["steps"]:
                step["output"] = _clip(step.get("output", ""), JSON_OUTPUT_LIMIT)
    (report_dir / "summary.json").write_text(
        json.dumps(stored, indent=2) + "\n",
        encoding="utf-8",
    )
    (report_dir / "summary.md").write_text(_summary(payload), encoding="utf-8")
    for track in payload["tracks"]:
        (report_dir / f"{track['id']}.md").write_text(
            _track(track),
            encoding="utf-8",
        )


def _summary(payload: dict) -> str:
    lines = [
        "# Showroom module tests",
        "",
        f"Started: {payload['started']}",
        f"Mode: {payload['mode']}",
        "",
        "| Track | Modules | Passed steps | Failed steps | Skipped steps | Not run | Content failures |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for track in payload["tracks"]:
        counts = _counts(track)
        lines.append(
            f"| {track['id']} | {counts['modules']} | {counts['passed']} | "
            f"{counts['failed']} | {counts['skipped']} | {counts['not_run']} | {counts['content']} |"
        )
    lines.extend(["", "## Failures", ""])
    failures = list(_failures(payload))
    if not failures:
        lines.append("None.")
    else:
        lines.extend(f"- {item}" for item in failures)
    lines.extend(["", "## Skipped commands", ""])
    skipped = list(_skipped(payload))
    if not skipped:
        lines.append("None.")
    else:
        lines.append(
            "These commands were not executed. The lab text above each one is included."
        )
        lines.append("")
        lines.extend(_skipped_blocks(skipped))
    lines.append("")
    return "\n".join(lines)


def _track(track: dict) -> str:
    lines = [f"# Track {track['id']}", ""]
    for module in track["modules"]:
        lines.append(f"## {module['id']} {module['title']}")
        lines.append("")
        lines.append(f"Page: `{module['page']}`")
        lines.append("")
        lines.append("### Content")
        lines.append("")
        for check in module["content_checks"]:
            mark = "PASS" if check["passed"] else "FAIL"
            detail = f" — {check['detail']}" if check["detail"] else ""
            lines.append(f"- {mark} {check['name']}{detail}")
        if module.get("namespace_resets"):
            lines.extend(["", "### Namespace reset", ""])
            for item in module["namespace_resets"]:
                state = "deleted" if item["deleted"] else "kept"
                detail = f" — {item['detail']}" if item["detail"] else ""
                lines.append(f"- {item['namespace']}: {state}{detail}")
        skipped = [
            {**step, "page": module["page"]}
            for step in module["steps"]
            if step["status"] == "skipped"
        ]
        if skipped:
            lines.extend(["", "### Skipped", ""])
            lines.extend(_skipped_blocks(skipped, include_module=False))
        lines.extend(["", "### Commands", ""])
        if not module["steps"]:
            lines.append("No executable commands.")
        for step in module["steps"]:
            lines.append(
                f"#### Step {step['index']} ({step['status']}, {step['expected_kind']})"
            )
            lines.append("")
            lines.append("```bash")
            lines.append(step["command"].rstrip())
            lines.append("```")
            lines.append("")
            if step["detail"]:
                lines.append(step["detail"])
                lines.append("")
            if step["missing_lines"]:
                lines.append("Missing expected lines:")
                lines.append("")
                for missing in step["missing_lines"]:
                    lines.append(f"- `{missing}`")
                lines.append("")
            if step["output"]:
                lines.append("<details><summary>Output</summary>")
                lines.append("")
                lines.append("```")
                lines.append(_clip(step["output"]))
                lines.append("```")
                lines.append("")
                lines.append("</details>")
                lines.append("")
        lines.append("")
    return "\n".join(lines)


def _counts(track: dict) -> dict[str, int]:
    passed = failed = skipped = not_run = content = 0
    for module in track["modules"]:
        content += sum(1 for check in module["content_checks"] if not check["passed"])
        for step in module["steps"]:
            if step["status"] == "skipped":
                skipped += 1
            elif step["status"] == "not-run":
                not_run += 1
            elif step["status"] == "failed":
                failed += 1
            elif step["status"] == "passed":
                passed += 1
    return {
        "modules": len(track["modules"]),
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "not_run": not_run,
        "content": content,
    }


def _failures(payload: dict) -> list[str]:
    items: list[str] = []
    for track in payload["tracks"]:
        for module in track["modules"]:
            for check in module["content_checks"]:
                if not check["passed"]:
                    detail = f": {check['detail']}" if check["detail"] else ""
                    items.append(f"{module['id']} content {check['name']}{detail}")
            for item in module.get("namespace_resets") or []:
                if not item["deleted"] and item["detail"] != "left in place":
                    items.append(f"{module['id']} namespace {item['namespace']}: {item['detail']}")
            for step in module["steps"]:
                if step["status"] == "failed":
                    detail = f": {step['detail']}" if step["detail"] else ""
                    items.append(f"{module['id']} step {step['index']}{detail}")
    return items


def _skipped(payload: dict) -> list[dict]:
    items = []
    for track in payload["tracks"]:
        for module in track["modules"]:
            for step in module["steps"]:
                if step["status"] == "skipped":
                    items.append({**step, "module_id": module["id"], "page": module["page"]})
    return items


def _skipped_blocks(steps: list[dict], include_module: bool = True) -> list[str]:
    lines: list[str] = []
    for step in steps:
        module_id = step.get("module_id", "")
        where = f"{module_id} step {step['index']}" if include_module and module_id else f"Step {step['index']}"
        reason = step.get("detail") or "skipped"
        lines.append(f"### {where} — {reason}")
        lines.append("")
        location = f"`{step['page']}` line {step['line']}" if step.get("page") else f"line {step['line']}"
        if step.get("section"):
            lines.append(f"{location}. **{step['section']}**")
        else:
            lines.append(location)
        lines.append("")
        if step.get("preamble"):
            lines.append(f"> {step['preamble']}")
            lines.append("")
        lines.append("```bash")
        lines.append(step["command"].rstrip())
        lines.append("```")
        lines.append("")
    return lines


def run_passed(payload: dict) -> bool:
    return not list(_failures(payload))


def _clip(text: str, limit: int = OUTPUT_LIMIT) -> str:
    stripped = text.rstrip()
    if len(stripped) <= limit:
        return stripped
    return stripped[:limit] + "\n...[truncated]"
