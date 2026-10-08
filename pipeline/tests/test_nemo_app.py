from bot.nemo import app as nemo_app


def test_listeners_run_on_a_pool_wider_than_bolts_default(monkeypatch):
    built = {}
    monkeypatch.setenv("NEMO_BOT_TOKEN", "xoxb-test")
    monkeypatch.setattr(nemo_app, "App", lambda **kwargs: built.update(kwargs) or object())
    for module in (nemo_app.handlers, nemo_app.command, nemo_app.surface):
        monkeypatch.setattr(module, "register", lambda *args: None)

    nemo_app.build()

    pool = built["listener_executor"]
    assert pool._max_workers == nemo_app.LISTENER_THREADS == 16
    pool.shutdown()
