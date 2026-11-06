"""Load an RHDP bastion CSV and run a remote bash script over SSH."""

from __future__ import annotations

import csv
import shlex
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_USER = "lab-user"
DEFAULT_PORT = 22
CONNECT_TIMEOUT = 20

# hostname/user match the gameify CSV. guid/ssh_command come from an RHDP export.
_ALIASES = {
    "guid": "guid",
    "hostname": "hostname",
    "host": "hostname",
    "port": "port",
    "username": "username",
    "user": "username",
    "password": "password",
    "ssh_command": "ssh_command",
}


@dataclass
class Bastion:
    guid: str
    hostname: str
    port: int
    username: str
    password: str


@dataclass
class HostResult:
    bastion: Bastion
    ok: bool
    lines: list[str]
    output: str


def header(bastion: Bastion) -> str:
    guid = bastion.guid or "-"
    return f"=== {guid} {bastion.username}@{bastion.hostname}:{bastion.port} ==="


def redact(text: str, secret: str) -> str:
    if secret and secret in text:
        return text.replace(secret, "********")
    return text


def load_bastions(csv_path: str) -> list[Bastion]:
    bastions: list[Bastion] = []
    with open(csv_path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise SystemExit(f"Error: CSV has no header row: {csv_path}")
        fields: dict[str, str] = {}
        for name in reader.fieldnames:
            if not name:
                continue
            key = _ALIASES.get(name.strip().lower())
            if key:
                fields[key] = name
        if "hostname" not in fields or "password" not in fields:
            found = ", ".join(reader.fieldnames)
            raise SystemExit(
                "Error: CSV must include hostname and password "
                f"(RHDP columns: guid,hostname,port,username,password,ssh_command). "
                f"Found: {found}"
            )
        for row_num, row in enumerate(reader, start=2):
            hostname = (row.get(fields["hostname"]) or "").strip()
            if not hostname:
                continue
            guid = ""
            if "guid" in fields:
                guid = (row.get(fields["guid"]) or "").strip()
            port_raw = str(DEFAULT_PORT)
            if "port" in fields:
                port_raw = (row.get(fields["port"]) or str(DEFAULT_PORT)).strip()
            username = DEFAULT_USER
            if "username" in fields:
                username = (row.get(fields["username"]) or DEFAULT_USER).strip() or DEFAULT_USER
            password = (row.get(fields["password"]) or "").strip()
            try:
                port = int(port_raw)
            except ValueError as exc:
                raise SystemExit(f"Error: invalid port on CSV row {row_num}: {port_raw}") from exc
            if port < 1 or port > 65535:
                raise SystemExit(f"Error: invalid port on CSV row {row_num}: {port_raw}")
            if not password:
                raise SystemExit(f"Error: empty password on CSV row {row_num} for host {hostname}")
            bastions.append(
                Bastion(
                    guid=guid,
                    hostname=hostname,
                    port=port,
                    username=username,
                    password=password,
                )
            )
    if not bastions:
        raise SystemExit(f"Error: no bastion rows found in {csv_path}")
    return bastions


def bastions_from_args(args) -> list[Bastion]:
    if args.csv_path:
        return load_bastions(args.csv_path)
    if args.hostname and args.password:
        return [
            Bastion(
                guid=(args.guid or "").strip(),
                hostname=args.hostname.strip(),
                port=args.port,
                username=(args.user or DEFAULT_USER).strip() or DEFAULT_USER,
                password=args.password,
            )
        ]
    raise SystemExit("Error: provide --csv PATH, or both -H/--hostname and -P/--password")


def add_connection_args(parser) -> None:
    parser.add_argument(
        "--csv",
        dest="csv_path",
        help="RHDP CSV: guid,hostname,port,username,password,ssh_command",
    )
    parser.add_argument("-H", "--hostname", help="Single bastion hostname")
    parser.add_argument("-P", "--password", help="SSH password for single-host mode")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="SSH port for single-host mode")
    parser.add_argument("--user", default=DEFAULT_USER, help="SSH user for single-host mode")
    parser.add_argument(
        "--guid",
        default="",
        help="Cluster guid for single-host mode (namespace showroom-<guid> or showroom-<guid>-<n>)",
    )
    parser.add_argument("--workers", type=int, default=5, help="Parallel SSH sessions (default 5)")


def ensure_paramiko():
    try:
        import paramiko
    except ImportError as exc:
        raise SystemExit(
            "Error: paramiko is not installed (python3 -m pip install -r requirements.txt)"
        ) from exc
    return paramiko


def run_remote(
    bastion: Bastion,
    script: str,
    args: list[str],
    timeout: float | None,
) -> tuple[int, str]:
    """Run script on the bastion. Returns (exit_code, combined output)."""
    paramiko = ensure_paramiko()
    quoted = " ".join(shlex.quote(arg) for arg in args)
    command = f"bash -s -- {quoted}" if quoted else "bash -s"
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=bastion.hostname,
            port=bastion.port,
            username=bastion.username,
            password=bastion.password,
            timeout=CONNECT_TIMEOUT,
            banner_timeout=CONNECT_TIMEOUT,
            auth_timeout=CONNECT_TIMEOUT,
            allow_agent=False,
            look_for_keys=False,
        )
        transport = client.get_transport()
        if transport is None:
            return 255, "Connection failed: SSH transport was not established"
        transport.set_keepalive(30)
        channel = transport.open_session(timeout=CONNECT_TIMEOUT)
        channel.set_combine_stderr(True)
        channel.exec_command(command)
        payload = script if script.endswith("\n") else script + "\n"
        channel.sendall(payload.encode("utf-8"))
        channel.shutdown_write()
        return _read_channel(channel, timeout)
    except Exception as exc:  # noqa: BLE001 - report any SSH failure per host
        return 255, f"Connection failed: {exc}"
    finally:
        client.close()


def _read_channel(channel, timeout: float | None) -> tuple[int, str]:
    chunks: list[bytes] = []
    deadline = time.monotonic() + timeout if timeout else None
    while True:
        if deadline is not None and time.monotonic() > deadline:
            channel.close()
            text = b"".join(chunks).decode("utf-8", errors="replace")
            return 124, text + "\nERROR: timed out waiting for the remote command\n"
        if channel.recv_ready():
            data = channel.recv(65536)
            if data:
                chunks.append(data)
                continue
        if channel.exit_status_ready():
            while channel.recv_ready():
                data = channel.recv(65536)
                if not data:
                    break
                chunks.append(data)
            break
        if channel.closed:
            break
        time.sleep(0.2)
    rc = channel.recv_exit_status()
    text = b"".join(chunks).decode("utf-8", errors="replace")
    return rc, text


def write_host_log(directory: Path, bastion: Bastion, output: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    label = bastion.guid or bastion.hostname
    safe = "".join(ch if ch.isalnum() or ch in ".-_" else "_" for ch in label)
    path = directory / f"{safe}-{bastion.port}.log"
    path.write_text(output, encoding="utf-8")
    return path


def execute_all(bastions: list[Bastion], worker, workers: int) -> list[HostResult]:
    if workers < 1:
        raise SystemExit("Error: --workers must be at least 1")
    results: list[HostResult | None] = [None] * len(bastions)
    print_lock = threading.Lock()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(worker, bastion): index for index, bastion in enumerate(bastions)}
        for future in as_completed(futures):
            index = futures[future]
            bastion = bastions[index]
            try:
                result = future.result()
            except Exception as exc:  # noqa: BLE001 - one host must not stop the rest
                text = redact(f"ERROR: {exc}", bastion.password)
                result = HostResult(bastion, False, [header(bastion), text], text)
            results[index] = result
            with print_lock:
                print("\n".join(result.lines))
                print()
    return [result for result in results if result is not None]


def append_results(path: Path, title: str, results: list[HostResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"\n# {title} {stamp}\n")
        for result in results:
            handle.write("\n".join(result.lines))
            handle.write("\n")

