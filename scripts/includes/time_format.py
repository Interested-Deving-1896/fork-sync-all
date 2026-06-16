"""
time_format.py — shared dual-format, world-timezone time display module

Provides human-readable time strings in both 12-hour and 24-hour formats
across every major world timezone, with auto-detection of the caller's
local timezone.

Usage (from any script):
    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    from time_format import fmt_unix, fmt_dt, world_table, detect_local_tz

    # Format a Unix timestamp
    info = fmt_unix(1718575200)
    print(info["display"])          # full single-line summary
    print(info["utc_24"])           # "23:10 UTC"
    print(info["utc_12"])           # "11:10 PM UTC"
    print(info["local_24"])         # detected local tz, 24h
    print(info["local_12"])         # detected local tz, 12h
    print(info["table"])            # markdown table of all zones
    print(info["json_extra"])       # dict for embedding in JSON outputs

    # Format a datetime object
    info = fmt_dt(datetime.now(timezone.utc))

    # Just the world table for a given timestamp
    print(world_table(1718575200))

    # Detect local timezone name
    print(detect_local_tz())        # e.g. "America/New_York"

CLI usage (called from bash):
    python3 scripts/includes/time_format.py <unix_timestamp> [format]

    format:
      display   — full single-line (default)
      utc24     — HH:MM UTC
      utc12     — H:MM AM/PM UTC
      local24   — local tz 24h
      local12   — local tz 12h
      table     — markdown table
      json      — JSON dict of all fields
      iso       — ISO 8601 with offset for local tz
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# ── World timezone registry ───────────────────────────────────────────────────
# Ordered by UTC offset (west → east). Each entry:
#   (iana_name, display_label, country, city/region)
#
# Covers all inhabited UTC offsets. DST-aware via zoneinfo.

# ── Portable 12-hour formatting ───────────────────────────────────────────────
# %-I (no-padding hour) is GNU/glibc-only. Fails on:
#   - Alpine Linux (musl libc)
#   - macOS (BSD libc) — uses %-I differently; %l is the BSD equivalent but
#     produces a leading space rather than nothing
#   - BusyBox date
#
# Portable alternative: use %I (zero-padded) then strip the leading zero.
# "12:00 AM" must not be stripped to "2:00 AM", so we guard with `or`.

def _fmt12(dt: "datetime", fmt: str = "%I:%M %p") -> str:
    """Return a no-leading-zero 12-hour time string, portable across all platforms."""
    return dt.strftime(fmt).lstrip("0") or ("12" + dt.strftime(":%M %p"))


def _fmt12s(dt: "datetime") -> str:
    """12-hour with seconds, portable."""
    return dt.strftime("%I:%M:%S %p").lstrip("0") or ("12" + dt.strftime(":%M:%S %p"))


WORLD_ZONES: list[tuple[str, str, str, str]] = [
    # UTC-12
    ("Etc/GMT+12",            "UTC−12",    "US",  "Baker Island"),
    # UTC-11
    ("Pacific/Pago_Pago",     "SST",       "AS",  "Pago Pago, American Samoa"),
    # UTC-10
    ("Pacific/Honolulu",      "HST",       "US",  "Honolulu, Hawaii"),
    ("Pacific/Tahiti",        "TAHT",      "PF",  "Papeete, French Polynesia"),
    # UTC-9:30
    ("Pacific/Marquesas",     "MART",      "PF",  "Marquesas Islands"),
    # UTC-9
    ("America/Anchorage",     "AKST/AKDT", "US",  "Anchorage, Alaska"),
    # UTC-8
    ("America/Los_Angeles",   "PST/PDT",   "US",  "Los Angeles / San Francisco"),
    ("America/Vancouver",     "PST/PDT",   "CA",  "Vancouver, BC"),
    ("America/Tijuana",       "PST/PDT",   "MX",  "Tijuana, Mexico"),
    # UTC-7
    ("America/Denver",        "MST/MDT",   "US",  "Denver / Phoenix"),
    ("America/Edmonton",      "MST/MDT",   "CA",  "Edmonton, AB"),
    ("America/Chihuahua",     "CST/CDT",   "MX",  "Chihuahua, Mexico"),
    # UTC-6
    ("America/Chicago",       "CST/CDT",   "US",  "Chicago / Dallas"),
    ("America/Winnipeg",      "CST/CDT",   "CA",  "Winnipeg, MB"),
    ("America/Mexico_City",   "CST/CDT",   "MX",  "Mexico City"),
    ("America/Guatemala",     "CST",       "GT",  "Guatemala City"),
    ("America/Costa_Rica",    "CST",       "CR",  "San José, Costa Rica"),
    # UTC-5
    ("America/New_York",      "EST/EDT",   "US",  "New York / Miami"),
    ("America/Toronto",       "EST/EDT",   "CA",  "Toronto, ON"),
    ("America/Bogota",        "COT",       "CO",  "Bogotá, Colombia"),
    ("America/Lima",          "PET",       "PE",  "Lima, Peru"),
    ("America/Havana",        "CST/CDT",   "CU",  "Havana, Cuba"),
    # UTC-4
    ("America/Halifax",       "AST/ADT",   "CA",  "Halifax, NS"),
    ("America/Caracas",       "VET",       "VE",  "Caracas, Venezuela"),
    ("America/La_Paz",        "BOT",       "BO",  "La Paz, Bolivia"),
    ("America/Santiago",      "CLT/CLST",  "CL",  "Santiago, Chile"),
    ("America/Manaus",        "AMT",       "BR",  "Manaus, Brazil"),
    ("Atlantic/Bermuda",      "AST/ADT",   "BM",  "Hamilton, Bermuda"),
    # UTC-3:30
    ("America/St_Johns",      "NST/NDT",   "CA",  "St. John's, NL"),
    # UTC-3
    ("America/Sao_Paulo",     "BRT/BRST",  "BR",  "São Paulo, Brazil"),
    ("America/Argentina/Buenos_Aires", "ART", "AR", "Buenos Aires, Argentina"),
    ("America/Montevideo",    "UYT",       "UY",  "Montevideo, Uruguay"),
    ("America/Godthab",       "WGT/WGST",  "GL",  "Nuuk, Greenland"),
    # UTC-2
    ("Atlantic/South_Georgia","GST",       "GS",  "South Georgia"),
    # UTC-1
    ("Atlantic/Azores",       "AZOT/AZOST","PT",  "Azores, Portugal"),
    ("Atlantic/Cape_Verde",   "CVT",       "CV",  "Praia, Cape Verde"),
    # UTC+0
    ("UTC",                   "UTC",       "—",   "Coordinated Universal Time"),
    ("Europe/London",         "GMT/BST",   "GB",  "London, UK"),
    ("Africa/Abidjan",        "GMT",       "CI",  "Abidjan, Côte d'Ivoire"),
    ("Africa/Accra",          "GMT",       "GH",  "Accra, Ghana"),
    ("Africa/Casablanca",     "WET/WEST",  "MA",  "Casablanca, Morocco"),
    # UTC+1
    ("Europe/Paris",          "CET/CEST",  "FR",  "Paris, France"),
    ("Europe/Berlin",         "CET/CEST",  "DE",  "Berlin, Germany"),
    ("Europe/Amsterdam",      "CET/CEST",  "NL",  "Amsterdam, Netherlands"),
    ("Europe/Madrid",         "CET/CEST",  "ES",  "Madrid, Spain"),
    ("Europe/Rome",           "CET/CEST",  "IT",  "Rome, Italy"),
    ("Europe/Warsaw",         "CET/CEST",  "PL",  "Warsaw, Poland"),
    ("Europe/Stockholm",      "CET/CEST",  "SE",  "Stockholm, Sweden"),
    ("Africa/Lagos",          "WAT",       "NG",  "Lagos, Nigeria"),
    ("Africa/Tunis",          "CET",       "TN",  "Tunis, Tunisia"),
    # UTC+2
    ("Europe/Helsinki",       "EET/EEST",  "FI",  "Helsinki, Finland"),
    ("Europe/Athens",         "EET/EEST",  "GR",  "Athens, Greece"),
    ("Europe/Bucharest",      "EET/EEST",  "RO",  "Bucharest, Romania"),
    ("Europe/Kiev",           "EET/EEST",  "UA",  "Kyiv, Ukraine"),
    ("Africa/Cairo",          "EET",       "EG",  "Cairo, Egypt"),
    ("Africa/Johannesburg",   "SAST",      "ZA",  "Johannesburg, South Africa"),
    ("Asia/Jerusalem",        "IST/IDT",   "IL",  "Jerusalem, Israel"),
    ("Asia/Beirut",           "EET/EEST",  "LB",  "Beirut, Lebanon"),
    # UTC+3
    ("Europe/Moscow",         "MSK",       "RU",  "Moscow, Russia"),
    ("Asia/Riyadh",           "AST",       "SA",  "Riyadh, Saudi Arabia"),
    ("Asia/Kuwait",           "AST",       "KW",  "Kuwait City"),
    ("Asia/Baghdad",          "AST",       "IQ",  "Baghdad, Iraq"),
    ("Africa/Nairobi",        "EAT",       "KE",  "Nairobi, Kenya"),
    ("Asia/Aden",             "AST",       "YE",  "Aden, Yemen"),
    # UTC+3:30
    ("Asia/Tehran",           "IRST/IRDT", "IR",  "Tehran, Iran"),
    # UTC+4
    ("Asia/Dubai",            "GST",       "AE",  "Dubai, UAE"),
    ("Asia/Muscat",           "GST",       "OM",  "Muscat, Oman"),
    ("Asia/Baku",             "AZT/AZST",  "AZ",  "Baku, Azerbaijan"),
    ("Asia/Tbilisi",          "GET",       "GE",  "Tbilisi, Georgia"),
    ("Asia/Yerevan",          "AMT/AMST",  "AM",  "Yerevan, Armenia"),
    ("Indian/Mauritius",      "MUT",       "MU",  "Port Louis, Mauritius"),
    # UTC+4:30
    ("Asia/Kabul",            "AFT",       "AF",  "Kabul, Afghanistan"),
    # UTC+5
    ("Asia/Karachi",          "PKT",       "PK",  "Karachi, Pakistan"),
    ("Asia/Tashkent",         "UZT",       "UZ",  "Tashkent, Uzbekistan"),
    ("Asia/Yekaterinburg",    "YEKT",      "RU",  "Yekaterinburg, Russia"),
    # UTC+5:30
    ("Asia/Kolkata",          "IST",       "IN",  "Mumbai / Delhi / Kolkata"),
    ("Asia/Colombo",          "SLST",      "LK",  "Colombo, Sri Lanka"),
    # UTC+5:45
    ("Asia/Kathmandu",        "NPT",       "NP",  "Kathmandu, Nepal"),
    # UTC+6
    ("Asia/Dhaka",            "BST",       "BD",  "Dhaka, Bangladesh"),
    ("Asia/Almaty",           "ALMT",      "KZ",  "Almaty, Kazakhstan"),
    ("Asia/Omsk",             "OMST",      "RU",  "Omsk, Russia"),
    # UTC+6:30
    ("Asia/Yangon",           "MMT",       "MM",  "Yangon, Myanmar"),
    # UTC+7
    ("Asia/Bangkok",          "ICT",       "TH",  "Bangkok, Thailand"),
    ("Asia/Ho_Chi_Minh",      "ICT",       "VN",  "Ho Chi Minh City, Vietnam"),
    ("Asia/Jakarta",          "WIB",       "ID",  "Jakarta, Indonesia"),
    ("Asia/Krasnoyarsk",      "KRAT",      "RU",  "Krasnoyarsk, Russia"),
    # UTC+8
    ("Asia/Shanghai",         "CST",       "CN",  "Beijing / Shanghai, China"),
    ("Asia/Hong_Kong",        "HKT",       "HK",  "Hong Kong"),
    ("Asia/Singapore",        "SGT",       "SG",  "Singapore"),
    ("Asia/Taipei",           "CST",       "TW",  "Taipei, Taiwan"),
    ("Asia/Kuala_Lumpur",     "MYT",       "MY",  "Kuala Lumpur, Malaysia"),
    ("Asia/Manila",           "PHT",       "PH",  "Manila, Philippines"),
    ("Australia/Perth",       "AWST",      "AU",  "Perth, Australia"),
    ("Asia/Irkutsk",          "IRKT",      "RU",  "Irkutsk, Russia"),
    # UTC+8:45
    ("Australia/Eucla",       "ACWST",     "AU",  "Eucla, Australia"),
    # UTC+9
    ("Asia/Tokyo",            "JST",       "JP",  "Tokyo, Japan"),
    ("Asia/Seoul",            "KST",       "KR",  "Seoul, South Korea"),
    ("Asia/Pyongyang",        "KST",       "KP",  "Pyongyang, North Korea"),
    ("Asia/Yakutsk",          "YAKT",      "RU",  "Yakutsk, Russia"),
    # UTC+9:30
    ("Australia/Darwin",      "ACST",      "AU",  "Darwin, Australia"),
    ("Australia/Adelaide",    "ACST/ACDT", "AU",  "Adelaide, Australia"),
    # UTC+10
    ("Australia/Sydney",      "AEST/AEDT", "AU",  "Sydney / Melbourne"),
    ("Australia/Brisbane",    "AEST",      "AU",  "Brisbane, Australia"),
    ("Pacific/Port_Moresby",  "PGT",       "PG",  "Port Moresby, PNG"),
    ("Asia/Vladivostok",      "VLAT",      "RU",  "Vladivostok, Russia"),
    # UTC+10:30
    ("Australia/Lord_Howe",   "LHST/LHDT", "AU",  "Lord Howe Island"),
    # UTC+11
    ("Pacific/Noumea",        "NCT",       "NC",  "Nouméa, New Caledonia"),
    ("Pacific/Guadalcanal",   "SBT",       "SB",  "Honiara, Solomon Islands"),
    ("Asia/Magadan",          "MAGT",      "RU",  "Magadan, Russia"),
    # UTC+12
    ("Pacific/Auckland",      "NZST/NZDT", "NZ",  "Auckland, New Zealand"),
    ("Pacific/Fiji",          "FJT/FJST",  "FJ",  "Suva, Fiji"),
    ("Asia/Kamchatka",        "PETT",      "RU",  "Petropavlovsk-Kamchatsky"),
    # UTC+12:45
    ("Pacific/Chatham",       "CHAST/CHADT","NZ", "Chatham Islands, NZ"),
    # UTC+13
    ("Pacific/Apia",          "WST",       "WS",  "Apia, Samoa"),
    ("Pacific/Tongatapu",     "TOT",       "TO",  "Nukuʻalofa, Tonga"),
    # UTC+14
    ("Pacific/Kiritimati",    "LINT",      "KI",  "Kiritimati, Kiribati"),
]

# ── Auto-detect local timezone ────────────────────────────────────────────────

def detect_local_tz() -> str:
    """Return the IANA timezone name for the caller's local timezone.

    Detection order:
      1. TZ environment variable (explicit override)
      2. /etc/timezone (Linux system timezone file)
      3. /etc/localtime symlink target (macOS / systemd)
      4. GITHUB_RUNNER_* hints (GitHub Actions runners are UTC)
      5. Falls back to UTC
    """
    # 1. Explicit env override
    tz_env = os.environ.get("TZ", "").strip()
    if tz_env:
        try:
            ZoneInfo(tz_env)
            return tz_env
        except (ZoneInfoNotFoundError, KeyError):
            pass

    # 2. /etc/timezone (Debian/Ubuntu)
    try:
        with open("/etc/timezone") as f:
            tz_name = f.read().strip()
            if tz_name:
                ZoneInfo(tz_name)
                return tz_name
    except Exception:
        pass

    # 3. /etc/localtime symlink (macOS, Arch, Alpine)
    try:
        import pathlib
        llt = pathlib.Path("/etc/localtime")
        if llt.is_symlink():
            target = str(llt.resolve())
            # Extract IANA name from path like /usr/share/zoneinfo/America/New_York
            if "zoneinfo/" in target:
                tz_name = target.split("zoneinfo/", 1)[1]
                ZoneInfo(tz_name)
                return tz_name
    except Exception:
        pass

    # 4. GitHub Actions runners are always UTC
    if os.environ.get("GITHUB_ACTIONS"):
        return "UTC"

    return "UTC"


# ── Core formatting ───────────────────────────────────────────────────────────

def _fmt_one(dt_utc: datetime, iana: str) -> dict[str, str]:
    """Format dt_utc in a single timezone. Returns dict with 24h, 12h, offset, abbr."""
    try:
        zi = ZoneInfo(iana)
        dt_local = dt_utc.astimezone(zi)
        abbr = dt_local.strftime("%Z")
        offset = dt_local.strftime("%z")
        # Format offset as ±HH:MM
        if offset and len(offset) >= 5:
            sign = offset[0]
            oh, om = offset[1:3], offset[3:5]
            offset_str = f"UTC{sign}{oh}:{om}" if om != "00" else f"UTC{sign}{oh}"
            offset_str = offset_str.replace("UTC+00", "UTC").replace("UTC-00", "UTC")
        else:
            offset_str = "UTC"
        return {
            "24h": dt_local.strftime("%H:%M"),
            "12h": _fmt12(dt_local),
            "date": dt_local.strftime("%Y-%m-%d"),
            "abbr": abbr,
            "offset": offset_str,
            "iso": dt_local.isoformat(),
        }
    except Exception:
        return {"24h": "??:??", "12h": "??:?? ??", "date": "????-??-??",
                "abbr": iana, "offset": "UTC?", "iso": ""}


def fmt_unix(ts: int | float) -> dict:
    """Format a Unix timestamp into dual-format world-timezone display."""
    dt_utc = datetime.fromtimestamp(float(ts), tz=timezone.utc)
    return _build(dt_utc)


def fmt_dt(dt: datetime) -> dict:
    """Format a datetime object (any tz) into dual-format world-timezone display."""
    dt_utc = dt.astimezone(timezone.utc)
    return _build(dt_utc)


def fmt_iso(iso_str: str) -> dict:
    """Format an ISO 8601 string into dual-format world-timezone display."""
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ",
                "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.strptime(iso_str, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return fmt_dt(dt)
        except ValueError:
            continue
    raise ValueError(f"Cannot parse ISO timestamp: {iso_str!r}")


def _build(dt_utc: datetime) -> dict:
    local_tz = detect_local_tz()

    utc_info   = _fmt_one(dt_utc, "UTC")
    local_info = _fmt_one(dt_utc, local_tz)

    # Build per-zone lookup for the table and json_extra
    zones_data = []
    for iana, label, country, city in WORLD_ZONES:
        info = _fmt_one(dt_utc, iana)
        zones_data.append({
            "iana":    iana,
            "label":   label,
            "country": country,
            "city":    city,
            **info,
        })

    # Single-line display: local first (if not UTC), then UTC, then key zones
    key_zones = ["America/New_York", "America/Los_Angeles", "Europe/London",
                 "Europe/Paris", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney"]
    key_parts = []
    seen = {local_tz, "UTC"}
    for iana in key_zones:
        if iana in seen:
            continue
        seen.add(iana)
        info = _fmt_one(dt_utc, iana)
        _, _, _, city = next((z for z in WORLD_ZONES if z[0] == iana),
                             (iana, iana, "", iana))
        city_short = city.split(",")[0].split("/")[0].strip()
        key_parts.append(f"{info['24h']} / {_fmt12(dt_utc.astimezone(ZoneInfo(iana)))} {info['abbr']} ({city_short})")

    # Only prepend local tz if it's meaningfully different from UTC
    # and not an Etc/* synthetic zone (those have no real city)
    local_is_real = (local_tz != "UTC" and not local_tz.startswith("Etc/"))
    if local_is_real:
        local_city = next((z[3] for z in WORLD_ZONES if z[0] == local_tz), local_tz)
        local_city_short = local_city.split(",")[0].split("/")[0].strip()
        local_str = (f"{local_info['24h']} / {local_info['12h']} "
                     f"{local_info['abbr']} ({local_city_short}, local)")
        display = (f"{local_str}  ·  "
                   f"{utc_info['24h']} / {utc_info['12h']} UTC  ·  "
                   + "  ·  ".join(key_parts))
    else:
        display = (f"{utc_info['24h']} / {utc_info['12h']} UTC  ·  "
                   + "  ·  ".join(key_parts))

    # Markdown table (compact — one row per zone)
    table_lines = [
        "| Timezone | Country | City / Region | 24h | 12h | UTC Offset |",
        "|---|---|---|---|---|---|",
    ]
    for z in zones_data:
        table_lines.append(
            f"| {z['label']} | {z['country']} | {z['city']} "
            f"| {z['24h']} | {z['12h']} {z['abbr']} | {z['offset']} |"
        )
    table = "\n".join(table_lines)

    # JSON-embeddable dict (for QUOTA_SNAPSHOT and other JSON outputs)
    json_extra = {
        "utc_24":        f"{utc_info['24h']} UTC",
        "utc_12":        f"{utc_info['12h']} UTC",
        "utc_date":      utc_info["date"],
        "utc_iso":       dt_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "local_tz":      local_tz,
        "local_24":      f"{local_info['24h']} {local_info['abbr']}",
        "local_12":      f"{local_info['12h']} {local_info['abbr']}",
        "local_offset":  local_info["offset"],
        "display":       display,
        "zones": {z["iana"]: {"24h": z["24h"], "12h": f"{z['12h']} {z['abbr']}",
                               "offset": z["offset"], "city": z["city"]}
                  for z in zones_data},
    }

    return {
        "dt_utc":     dt_utc,
        "utc_24":     f"{utc_info['24h']} UTC",
        "utc_12":     f"{utc_info['12h']} UTC",
        "utc_iso":    dt_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "local_tz":   local_tz,
        "local_24":   f"{local_info['24h']} {local_info['abbr']}",
        "local_12":   f"{local_info['12h']} {local_info['abbr']}",
        "local_offset": local_info["offset"],
        "display":    display,
        "table":      table,
        "json_extra": json_extra,
        "zones_data": zones_data,
    }


# ── Compact summary for step logs (no table) ──────────────────────────────────

def compact(ts: int | float | None = None, dt: datetime | None = None) -> str:
    """Return a compact one-liner: '23:10 / 11:10 PM UTC · 6:10 / 6:10 PM ET · ...'"""
    if ts is not None:
        info = fmt_unix(ts)
    elif dt is not None:
        info = fmt_dt(dt)
    else:
        info = fmt_dt(datetime.now(timezone.utc))
    return info["display"]


# ── CLI entry point ───────────────────────────────────────────────────────────

def _cli():
    args = sys.argv[1:]
    if not args:
        # No args: format current time
        ts = datetime.now(timezone.utc).timestamp()
        fmt = "display"
    elif len(args) == 1:
        try:
            ts = float(args[0])
            fmt = "display"
        except ValueError:
            # Might be an ISO string
            try:
                info = fmt_iso(args[0])
                print(info["display"])
                return
            except ValueError:
                fmt = args[0]
                ts = datetime.now(timezone.utc).timestamp()
    else:
        try:
            ts = float(args[0])
        except ValueError:
            try:
                info = fmt_iso(args[0])
                fmt = args[1] if len(args) > 1 else "display"
            except ValueError:
                print(f"Cannot parse: {args[0]}", file=sys.stderr)
                sys.exit(1)
            _print_fmt(info, fmt)
            return
        fmt = args[1] if len(args) > 1 else "display"

    info = fmt_unix(ts)
    _print_fmt(info, fmt)


def _print_fmt(info: dict, fmt: str):
    if fmt == "display":
        print(info["display"])
    elif fmt == "utc24":
        print(info["utc_24"])
    elif fmt == "utc12":
        print(info["utc_12"])
    elif fmt == "local24":
        print(info["local_24"])
    elif fmt == "local12":
        print(info["local_12"])
    elif fmt == "table":
        print(info["table"])
    elif fmt == "json":
        print(json.dumps(info["json_extra"], indent=2))
    elif fmt == "iso":
        print(info["utc_iso"])
    else:
        print(info["display"])


# ── Self-test suite (--test flag) ─────────────────────────────────────────────

def _run_tests():
    """Portable self-test. Run with: python3 time_format.py --test"""
    import platform
    failures: list[str] = []

    def check(label: str, got: str, expected: str):
        if got != expected:
            failures.append(f"  FAIL [{label}]: got {got!r}, expected {expected!r}")
        else:
            print(f"  ok   [{label}]: {got}")

    print(f"\ntime_format.py self-test — Python {sys.version.split()[0]}"
          f" on {platform.system()} ({platform.machine()})\n")

    # ── _fmt12 edge cases ─────────────────────────────────────────────────────
    midnight = datetime(2026, 1, 1,  0,  0, 0, tzinfo=timezone.utc)
    noon     = datetime(2026, 1, 1, 12,  0, 0, tzinfo=timezone.utc)
    one_am   = datetime(2026, 1, 1,  1,  5, 0, tzinfo=timezone.utc)
    one_pm   = datetime(2026, 1, 1, 13,  5, 0, tzinfo=timezone.utc)
    eleven_pm= datetime(2026, 1, 1, 23, 59, 0, tzinfo=timezone.utc)

    check("midnight 12h",  _fmt12(midnight),  "12:00 AM")
    check("noon 12h",      _fmt12(noon),      "12:00 PM")
    check("1:05 AM 12h",   _fmt12(one_am),    "1:05 AM")
    check("1:05 PM 12h",   _fmt12(one_pm),    "1:05 PM")
    check("11:59 PM 12h",  _fmt12(eleven_pm), "11:59 PM")

    # ── _fmt12s (with seconds) ────────────────────────────────────────────────
    check("midnight 12h+s", _fmt12s(midnight),  "12:00:00 AM")
    check("1:05:30 AM 12h+s", _fmt12s(datetime(2026,1,1,1,5,30,tzinfo=timezone.utc)), "1:05:30 AM")

    # ── fmt_unix round-trip ───────────────────────────────────────────────────
    # Use a known fixed timestamp: 2024-03-15 14:30:00 UTC (no DST ambiguity)
    ts = 1710513000  # 2024-03-15T14:30:00Z
    info = fmt_unix(ts)
    check("fmt_unix utc_24",  info["utc_24"], "14:30 UTC")
    check("fmt_unix utc_12",  info["utc_12"], "2:30 PM UTC")
    check("fmt_unix utc_iso", info["utc_iso"], "2024-03-15T14:30:00Z")

    # ── Zone count ────────────────────────────────────────────────────────────
    zone_count = len(info["zones_data"])
    if zone_count < 100:
        failures.append(f"  FAIL [zone count]: only {zone_count} zones (expected ≥100)")
    else:
        print(f"  ok   [zone count]: {zone_count} zones")

    # ── Key zones present ─────────────────────────────────────────────────────
    zone_ianas = {z["iana"] for z in info["zones_data"]}
    for iana in ["America/New_York", "Europe/London", "Asia/Tokyo", "Australia/Sydney"]:
        if iana not in zone_ianas:
            failures.append(f"  FAIL [zone present]: {iana} missing")
        else:
            print(f"  ok   [zone present]: {iana}")

    # ── No %-I in output strings ──────────────────────────────────────────────
    for key in ("utc_12", "local_12", "display"):
        val = info.get(key, "")
        if "%-I" in val:
            failures.append(f"  FAIL [no %-I in {key}]: found %-I in {val!r}")
        else:
            print(f"  ok   [no %-I in {key}]")

    # ── detect_local_tz returns a valid IANA name ─────────────────────────────
    tz_name = detect_local_tz()
    try:
        ZoneInfo(tz_name)
        print(f"  ok   [detect_local_tz]: {tz_name}")
    except Exception:
        failures.append(f"  FAIL [detect_local_tz]: {tz_name!r} is not a valid IANA name")

    # ── fmt_iso round-trip ────────────────────────────────────────────────────
    iso_info = fmt_iso("2024-03-15T14:30:00Z")
    check("fmt_iso utc_24", iso_info["utc_24"], "14:30 UTC")

    # ── Summary ───────────────────────────────────────────────────────────────
    print()
    if failures:
        print(f"FAILED ({len(failures)} failures):")
        for f in failures:
            print(f)
        sys.exit(1)
    else:
        print(f"All tests passed on {platform.system()}.")


if __name__ == "__main__":
    if "--test" in sys.argv:
        _run_tests()
    else:
        _cli()
