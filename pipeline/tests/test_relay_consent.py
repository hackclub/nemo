from bot.relay import consent


def checkbox(blocks):
    return next(block for block in blocks if block.get("block_id") == consent.BLOCK)["elements"][0]


def state(*values):
    return {"values": {consent.BLOCK: {consent.ACTION: {
        "selected_options": [{"value": value} for value in values],
    }}}}


def test_identity_option_keeps_label_and_describes_both_choices():
    option = consent.IDENTITY_OPTION

    assert option["text"]["text"] == "Include my username"
    assert option["description"]["text"] == (
        "FD will see who filed this report. Leave unchecked to stay anonymous.")
    assert option["value"] == consent.WITH_USERNAME


def test_checkbox_offers_the_described_option():
    assert checkbox(consent.build_blocks())["options"] == [consent.IDENTITY_OPTION]


def test_checkbox_starts_unchecked_without_saved_choice():
    assert "initial_options" not in checkbox(consent.build_blocks())


def test_checkbox_starts_checked_for_saved_named_choice():
    assert checkbox(consent.build_blocks(saved_choice=consent.NAMED))["initial_options"] == [consent.IDENTITY_OPTION]
    assert "initial_options" not in checkbox(consent.build_blocks(saved_choice=consent.ANONYMOUS))


def test_submitted_values_checked_is_named_unchecked_is_anonymous():
    assert consent.submitted_values(state(consent.WITH_USERNAME)) == consent.NAMED
    assert consent.submitted_values(state()) == consent.ANONYMOUS


def test_resolve_choice_without_state_or_saved_choice_is_anonymous():
    assert consent.resolve_choice(None) == consent.ANONYMOUS
    assert consent.resolve_choice(None, consent.NAMED) == consent.NAMED
