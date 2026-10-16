import pytest

from data.market_path import minute_marks


def build(rows, **kwargs):
    return minute_marks(rows, start=120, minutes=3, coverage_start=0, coverage_end=300, **kwargs)


def test_closed_minutes_and_initial_mark_never_use_future_fills():
    rows = [(100, 1000), (130, 1100), (179, 1300), (180, 900), (250, 800)]
    a = build(rows)
    assert a["prices_pns"] == [1000, 1200, 900, 800]
    assert a["fills_per_minute"] == [0, 2, 1, 1]
    changed = build(rows[:-1] + [(250, 999999), (300, 1), (1000, 999999)])
    assert changed["prices_pns"][:3] == a["prices_pns"][:3]


def test_empty_minutes_carry_past_mark_without_backfill():
    assert build([(100, 1000), (250, 800)])["prices_pns"] == [1000, 1000, 1000, 800]
    with pytest.raises(ValueError, match="future backfill"):
        build([(120, 1000), (250, 800)])


def test_tied_initial_timestamp_and_even_median_are_order_independent():
    rows = [(100, 1000), (100, 1003), (130, 1100), (130, 1101)]
    assert build(rows)["prices_pns"] == [1001, 1100, 1100, 1100]
    assert build(rows) == build(reversed(rows))


@pytest.mark.parametrize("bounds", [dict(coverage_start=121, coverage_end=300),
                                   dict(coverage_start=0, coverage_end=299)])
def test_missing_initial_or_terminal_coverage_refuses(bounds):
    with pytest.raises(ValueError, match="coverage"):
        minute_marks([(100, 1000)], start=120, minutes=3, **bounds)


@pytest.mark.parametrize("rows", [[(100, 0)], [(100, True)], [(float("nan"), 1000)]])
def test_invalid_observations_refuse(rows):
    with pytest.raises(ValueError):
        build(rows)
