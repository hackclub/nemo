from datetime import date

METHOD = "admin.analytics.getAvailableDateRange"

_cache = {}


def available(client, kind="member"):
    if kind in _cache:
        return _cache[kind]
    resp = client.call(METHOD, {"type": kind})
    rng = resp.get("available_date_range") or resp
    window = date.fromisoformat(rng["start_date"]), date.fromisoformat(rng["end_date"])
    _cache[kind] = window
    return window


def available_iso(client, kind="member"):
    start, end = available(client, kind)
    return {"start_date": start.isoformat(), "end_date": end.isoformat()}


def clear():
    _cache.clear()
