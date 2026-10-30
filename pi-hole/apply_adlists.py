#!/usr/bin/env python3
"""Add Git-managed adlists to the local Pi-hole v6 instance, then update Gravity."""

import getpass
import json
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

DIRECTORY = Path(__file__).resolve().parent
API = "http://127.0.0.1:8001/api"


def read_adlists():
    addresses = []
    for number, line in enumerate((DIRECTORY / "adlists.txt").read_text().splitlines(), 1):
        address = line.strip()
        if not address or address.startswith("#"):
            continue
        parsed = urlsplit(address)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.fragment
            or any(character.isspace() for character in address)
        ):
            raise ValueError(f"adlists.txt:{number}: expected an HTTPS URL without credentials or a fragment")
        if address not in addresses:
            addresses.append(address)
    if not addresses:
        raise ValueError("adlists.txt contains no URLs")
    return addresses


def request(method, path, payload=None, sid=None):
    headers = {"Content-Type": "application/json"}
    if sid:
        headers["X-FTL-SID"] = sid
    data = json.dumps(payload).encode() if payload is not None else None
    req = Request(API + path, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=30) as response:
            body = response.read()
    except HTTPError as error:
        raise RuntimeError(f"Pi-hole API {method} {path}: HTTP {error.code}") from error
    if not body:
        return {}
    result = json.loads(body)
    if not isinstance(result, dict):
        raise ValueError("Pi-hole API returned an unexpected response")
    if result.get("error"):
        raise RuntimeError(f"Pi-hole API {method} {path}: {result['error']}")
    return result


def main():
    addresses = read_adlists()
    # Fail before changing lists if Docker/the container is unavailable.
    compose = ["docker", "compose", "-f", str(DIRECTORY / "docker-compose.yml")]
    subprocess.run([*compose, "exec", "-T", "pihole", "true"], check=True)
    session = request("POST", "/auth", {"password": getpass.getpass("Pi-hole password: ")})["session"]
    if not session["valid"]:
        raise RuntimeError("Pi-hole authentication failed")
    sid = session["sid"]
    try:
        existing = {item["address"]: item for item in request("GET", "/lists?type=block", sid=sid)["lists"]}
        for address in addresses:
            if address in existing:
                status = "enabled" if existing[address]["enabled"] else "disabled; left unchanged"
                print(f"Already present ({status}): {address}", flush=True)
                continue
            result = request(
                "POST",
                "/lists?type=block",
                {"address": address, "enabled": True, "groups": [0], "comment": "Added from Git: pi-hole/adlists.txt"},
                sid=sid,
            )
            processed = result["processed"]
            if processed["errors"] or not any(item["item"] == address for item in processed["success"]):
                raise RuntimeError(f"Pi-hole did not add {address}: {processed}")
            print(f"Added: {address}", flush=True)
    finally:
        if sid:
            try:
                request("DELETE", "/auth", sid=sid)
            except (RuntimeError, URLError, OSError, ValueError) as error:
                print(f"Warning: could not close API session: {error}", file=sys.stderr)
    subprocess.run([*compose, "exec", "-T", "pihole", "pihole", "-g"], check=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, URLError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        sys.exit(f"Error: {error}")
