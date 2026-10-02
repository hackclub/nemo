import logging
import re
import threading

log = logging.getLogger("bot.nemo")

WORD = "word"
SUBSTRING = "substring"
REGEX = "regex"

FLAG = "flag"

LIVE = """
SELECT id, word, match_mode, effect, category_key
FROM fd.automod_words
WHERE active
ORDER BY id
"""

RECORD = """
INSERT INTO fd.automod_matches
    (word_id, word, effect, user_id, channel_id, message_ts, thread_ts, body)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (channel_id, message_ts, word) DO NOTHING
RETURNING id
"""

LINK = "UPDATE fd.automod_matches SET permalink = %s WHERE id = ANY(%s)"

_watching = []
_loaded = False
_lock = threading.Lock()


class Watch:
    def __init__(self, word_id, word, match_mode, effect, category_key):
        self.word_id = word_id
        self.word = word
        self.match_mode = match_mode
        self.effect = effect
        self.category_key = category_key
        self.pattern = compile_one(word, match_mode)

    def hits(self, said):
        return bool(self.pattern and self.pattern.search(said))


def compile_one(word, match_mode):
    said = (word or "").strip()
    if not said:
        return None
    try:
        if match_mode == REGEX:
            return re.compile(said, re.IGNORECASE)
        if match_mode == SUBSTRING:
            return re.compile(re.escape(said), re.IGNORECASE)
        return re.compile(rf"(?<![0-9A-Za-z]){re.escape(said)}(?![0-9A-Za-z])", re.IGNORECASE)
    except re.error as failure:
        log.warning("nemo: automod word %r does not compile: %s", said, failure)
        return None


def refresh(conn):
    global _loaded
    found = []
    for row in conn.execute(LIVE).fetchall():
        watch = Watch(*row)
        if watch.pattern is not None:
            found.append(watch)
    with _lock:
        _watching[:] = found
        _loaded = True
    return len(found)


def watching():
    with _lock:
        return list(_watching) if _loaded else None


def caught(said):
    held = watching()
    if not held or not said:
        return []
    return [one for one in held if one.hits(said)]


def record(conn, watch, said):
    return conn.execute(RECORD, (
        watch.word_id, watch.word, watch.effect, said.get("user"), said.get("channel"),
        said.get("ts"), said.get("thread_ts"), said.get("text"),
    )).fetchone()


def link(conn, ids, permalink):
    if not ids or not permalink:
        return 0
    conn.execute(LINK, (permalink, list(ids)))
    return len(ids)
