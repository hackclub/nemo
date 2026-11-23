from bot.nemo import app as nemo_app


def test_build_listener_executor_has_16_workers(monkeypatch):
    app_kwargs = {}
    monkeypatch.setenv("NEMO_BOT_TOKEN", "xoxb-test")
    monkeypatch.setattr(nemo_app, "App", lambda **kwargs: app_kwargs.update(kwargs) or object())
    for module in (nemo_app.handlers, nemo_app.command, nemo_app.publicize, nemo_app.surface):
        monkeypatch.setattr(module, "register", lambda *args: None)

    nemo_app.build()

    pool = app_kwargs["listener_executor"]
    assert pool._max_workers == nemo_app.LISTENER_THREADS == 16
    pool.shutdown()
