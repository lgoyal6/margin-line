"""Causal minute marks from retained maker fills, in integer price units."""
from __future__ import annotations

import math
from collections.abc import Iterable


def _median(prices: list[int]) -> int:
    prices = sorted(prices)
    return (prices[(len(prices) - 1) // 2] + prices[len(prices) // 2]) // 2


def minute_marks(
    fills: Iterable[tuple[float, int]], *, start: int, minutes: int,
    coverage_start: float, coverage_end: float,
) -> dict:
    """Use only fills strictly before each mark's timestamp.

    The initial mark uses the median at the latest pre-start timestamp.
    Later marks use the previous closed minute's median, carrying the prior
    mark if that minute has no fills. Caller-supplied coverage bounds must
    come from an independently retained history manifest, not the last fill.
    """
    if type(start) is not int or type(minutes) is not int or minutes <= 0:
        raise ValueError("start must be integer seconds and minutes positive")
    end = start + minutes * 60
    if not all(math.isfinite(t) for t in (coverage_start, coverage_end)):
        raise ValueError("coverage bounds must be finite")
    if coverage_start > start or coverage_end < end:
        raise ValueError("missing initial or terminal history coverage")
    data = []
    for timestamp, price in fills:
        if not math.isfinite(timestamp):
            raise ValueError("fill timestamps must be finite")
        if timestamp >= end:
            continue
        if type(price) is not int or price <= 0:
            raise ValueError("fill prices must be positive integer units")
        data.append((timestamp, price))
    data.sort()
    before = [(t, p) for t, p in data if t < start]
    if not before:
        raise ValueError("no pre-start fill; future backfill is forbidden")
    initial_time = before[-1][0]
    previous = _median([p for t, p in before if t == initial_time])
    prices, counts = [previous], [0]
    index = len(before)
    for minute in range(1, minutes + 1):
        stop = start + minute * 60
        bucket = []
        while index < len(data) and data[index][0] < stop:
            bucket.append(data[index][1])
            index += 1
        if bucket:
            previous = _median(bucket)
        prices.append(previous)
        counts.append(len(bucket))
    return {"start": start, "end": end, "initial_fill_timestamp": initial_time,
            "prices_pns": prices, "fills_per_minute": counts}
