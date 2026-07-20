#!/usr/bin/env python3
"""Build the bundled country-to-CIDR table used by VPN split routing."""

from __future__ import annotations

import datetime as dt
import gzip
import ipaddress
import io
import json
import os
from pathlib import Path
import tarfile
import urllib.request


SOURCES = {
    "ipv4": "https://www.ipdeny.com/ipblocks/data/countries/all-zones.tar.gz",
    "ipv6": "https://www.ipdeny.com/ipv6/ipaddresses/blocks/ipv6-all-zones.tar.gz",
}
OUTPUT = Path(__file__).resolve().parents[1] / "assets/geoip/country_routes.json.gz"


def download(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "xVeil-GeoIP-Updater/1.0 (+https://ipdeny.com)"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def read_zones(archive: bytes, family: int) -> dict[str, list[ipaddress._BaseNetwork]]:
    countries: dict[str, list[ipaddress._BaseNetwork]] = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        for member in bundle.getmembers():
            name = Path(member.name).name
            if not member.isfile() or not name.endswith(".zone"):
                continue
            code = name.removesuffix(".zone").upper()
            if len(code) != 2 or not code.isalpha():
                continue
            extracted = bundle.extractfile(member)
            if extracted is None:
                continue
            networks = countries.setdefault(code, [])
            for raw in extracted.read().decode("ascii").splitlines():
                value = raw.strip()
                if not value:
                    continue
                network = ipaddress.ip_network(value, strict=True)
                if network.version != family:
                    raise ValueError(f"{code}: unexpected IPv{network.version} route {value}")
                networks.append(network)
    return countries


def main() -> None:
    combined: dict[str, list[ipaddress._BaseNetwork]] = {}
    for label, url in SOURCES.items():
        family = 4 if label == "ipv4" else 6
        for code, networks in read_zones(download(url), family).items():
            combined.setdefault(code, []).extend(networks)

    routes = {}
    for code, networks in sorted(combined.items()):
        ipv4 = (network for network in networks if network.version == 4)
        ipv6 = (network for network in networks if network.version == 6)
        routes[code] = [
            str(network)
            for family in (ipv4, ipv6)
            for network in ipaddress.collapse_addresses(family)
        ]
    payload = {
        "schema": 1,
        "generatedAt": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat(),
        "source": "IPdeny country IP blocks",
        "sourceUrl": "https://www.ipdeny.com/ipblocks/",
        "countries": routes,
    }
    encoded = json.dumps(
        payload,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    temporary = OUTPUT.with_suffix(".tmp")
    with temporary.open("wb") as destination:
        with gzip.GzipFile(fileobj=destination, mode="wb", mtime=0) as compressed:
            compressed.write(encoded)
    os.replace(temporary, OUTPUT)
    print(f"wrote {OUTPUT}: {len(routes)} country codes, {len(encoded)} bytes JSON")


if __name__ == "__main__":
    main()
