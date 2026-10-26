#!/usr/bin/env python3
"""Run showroom module tests for one track, one module, or every track."""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.parse import load_tracks, namespaces_in_text, substitute
from lib.report import run_passed, write_report
from lib.runner import BashSession, load_attributes, reset_namespaces, run_step


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--track", help="Track id: 101, 201, 301, acs, tssc, or virt")
    parser.add_argument("--module", help="Module id, for example 101-01 or acs-00")
    parser.add_argument(
        "--content-only",
        action="store_true",
        help="Check pages, links, fences, and images without running commands",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=45,
        help="Seconds to wait for a command that does not set its own --timeout (default 45)",
    )
    args = parser.parse_args(argv)
    repo = Path(__file__).resolve().parents[1]
    tracks = load_tracks(repo)
    known = {track.id for track in tracks}
    if args.track and args.track not in known:
        print(f"Unknown track {args.track}. Choose from: {', '.join(sorted(known))}", file=sys.stderr)
        return 2
    if args.track:
        tracks = [track for track in tracks if track.id == args.track]
    if args.module:
        tracks = _filter_module(tracks, args.module)
        if not tracks:
            print(f"Unknown module {args.module}", file=sys.stderr)
            return 2

    attrs: dict[str, str] = {}
    if not args.content_only:
        try:
            attrs = load_attributes()
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 2

    started = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    payload_tracks = []
    for track in tracks:
        modules = []
        for module in track.modules:
            modules.append(_run_module(repo, module, attrs, args.content_only, args.timeout))
        payload_tracks.append({"id": track.id, "modules": modules})

    payload = {
        "started": started,
        "mode": "content-only" if args.content_only else "full",
        "tracks": payload_tracks,
    }
    report_dir = repo / "tests" / "reports" / started
    write_report(report_dir, payload)
    passed = run_passed(payload)
    print(f"Report: {report_dir / 'summary.md'}")
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


def _filter_module(tracks, module_id: str):
    selected = []
    for track in tracks:
        modules = [module for module in track.modules if module.id == module_id]
        if modules:
            track.modules = modules
            selected.append(track)
    return selected


def _run_module(repo, module, attrs, content_only: bool, timeout: int) -> dict:
    resets = []
    steps = []
    if content_only:
        for step in module.steps:
            steps.append(
                {
                    "index": step.index,
                    "line": step.line,
                    "command": step.command,
                    "expected_kind": step.expected_kind,
                    "status": "skipped" if step.skipped else "not-run",
                    "exit_code": None,
                    "detail": step.skip_reason if step.skipped else "content-only",
                    "missing_lines": [],
                    "output": "",
                    "section": step.section,
                    "preamble": step.preamble,
                }
            )
    else:
        resolved: list[str] = []
        for step in module.steps:
            command = substitute(step.command, attrs)
            for name in namespaces_in_text(command):
                if name not in resolved:
                    resolved.append(name)
        total = len(module.steps)
        print(f"== {module.id} ({total} commands)", flush=True)
        resets = reset_namespaces(resolved)
        session = BashSession(repo)
        try:
            for step in module.steps:
                first = step.command.strip().splitlines()[0][:100]
                print(f"{module.id} {step.index}/{total} {first}", flush=True)

                def on_wait(elapsed: int, label: str = first, index: int = step.index) -> None:
                    print(f"{module.id} {index}/{total} still running {elapsed}s  {label}", flush=True)

                result = run_step(session, step, attrs, timeout, on_wait=on_wait)
                result["section"] = step.section
                result["preamble"] = step.preamble
                detail = f"  {result['detail']}" if result["detail"] else ""
                print(f"{module.id} {step.index}/{total} {result['status']}{detail}", flush=True)
                steps.append(result)
        finally:
            session.close()
    return {
        "id": module.id,
        "title": module.title,
        "page": module.page,
        "content_checks": module.content_checks,
        "namespace_resets": resets,
        "steps": steps,
    }


if __name__ == "__main__":
    sys.exit(main())
