_known = {}


def bot_user_id(client, name):
    if name not in _known:
        _known[name] = client.auth_test()["user_id"]
    return _known[name]


def forget():
    _known.clear()
