from datetime import date, timedelta


def month_start(day):
    return day.replace(day=1)


def next_month(day):
    return date(day.year + day.month // 12, day.month % 12 + 1, 1)


def month_key(day):
    return day.strftime("%Y-%m")


def day(floor, edge, covered, limit=None, newest_first=True):
    missing, cursor = [], floor
    while cursor <= edge:
        if cursor not in covered and cursor.isoformat() not in covered:
            missing.append(cursor)
        cursor += timedelta(days=1)
    if newest_first:
        missing.reverse()
    if limit is not None:
        if limit < 1:
            return []
        missing = missing[:limit]
    return missing


def month(floor, edge, covered, complete_only=False):
    last = month_start(edge)
    if complete_only and next_month(last) - timedelta(days=1) > edge:
        last = month_start(last - timedelta(days=1))
    months, cursor = [], month_start(floor)
    while cursor <= last:
        if month_key(cursor) not in covered:
            months.append(cursor)
        cursor = next_month(cursor)
    return months


def window(floor, edge, days=None, end=None):
    stop = min(end or edge, edge)
    if days is None:
        return floor, stop
    return max(floor, stop - timedelta(days=days - 1)), stop


def snapshot(edge, covered):
    return [] if edge in covered or edge.isoformat() in covered else [edge]


def slice_key(start, stop):
    return start.isoformat() if start == stop else f"{start}..{stop}"
