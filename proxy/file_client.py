import os
import urllib.error
import urllib.parse
import urllib.request

READ = "files.read"
METHODS = frozenset({READ})

UPSTREAM_TIMEOUT = 30
MOST_BYTES = 12 * 1024 * 1024
SLACK_HOSTS = (".slack.com", ".slack-edge.com")
FALLBACK_TYPE = "application/octet-stream"


class FileError(RuntimeError):
    """Slack would not hand over the file"""


def cookie():
    said = os.environ.get("SLACK_D_COOKIE", "").strip()
    if not said:
        raise FileError("SLACK_D_COOKIE must be set to read a file")
    return said


def hosted_by_slack(url):
    host = urllib.parse.urlparse(url).hostname or ""
    return any(host == one.lstrip(".") or host.endswith(one) for one in SLACK_HOSTS)


def url_of(params):
    said = str(params.get("url") or "").strip()
    if not said:
        raise FileError("url is required")
    if not said.startswith("https://"):
        raise FileError("the file url must be https")
    if not hosted_by_slack(said):
        raise FileError("the file is not hosted by slack")
    return said


def read(params):
    url = url_of(params)
    asked = urllib.request.Request(url, headers={"Cookie": f"d={cookie()}"})
    try:
        with urllib.request.urlopen(asked, timeout=UPSTREAM_TIMEOUT) as answer:
            body = answer.read(MOST_BYTES + 1)
            kind = answer.headers.get("Content-Type") or FALLBACK_TYPE
    except urllib.error.HTTPError as failure:
        raise FileError(f"slack answered {failure.code} for the file") from failure
    except urllib.error.URLError as failure:
        raise FileError(f"slack could not be reached for the file: {failure.reason}") from failure

    if len(body) > MOST_BYTES:
        raise FileError("the file is larger than the proxy will carry")
    if kind.startswith("text/html"):
        raise FileError("slack answered with a sign-in page, not the file")
    return body, kind
