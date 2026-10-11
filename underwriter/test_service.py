import unittest

from service import decide, evaluate_rules


class UnderwriterTests(unittest.TestCase):
    def test_unknown_address_denied_without_history(self):
        result = decide("0x0000000000000000000000000000000000000001")
        self.assertFalse(result.eligible)
        self.assertEqual(result.limit_ausd, 0)

    def test_unknown_address_is_explicit_demo_only(self):
        result = decide("0x0000000000000000000000000000000000000001", demo=True)
        self.assertTrue(result.eligible)
        self.assertTrue(result.simulated)
        self.assertEqual(result.limit_ausd, 100)

    def test_real_backtest_approved_address_matches_rule(self):
        result = decide("0x4a57583c38e84a27c4a397d49dc7cdc8cfffec92")
        self.assertTrue(result.eligible)
        self.assertFalse(result.simulated)
        self.assertGreater(result.limit_ausd, 0)
        self.assertTrue(all(item.passed for item in result.explanation))

    def test_each_fixed_rule_has_a_failing_case(self):
        base = {"active_days": 3, "n_closes": 10, "liq_hist": 0, "pnl_ext": 1.0, "avg_lev": 5.0, "wash_pair": False}
        for field in base:
            row = dict(base)
            row[field] = {"active_days": 2, "n_closes": 9, "liq_hist": 1, "pnl_ext": 0.0,
                          "avg_lev": 5.1, "wash_pair": True}[field]
            failed = {item.field for item in evaluate_rules(row) if not item.passed}
            self.assertEqual(failed, {field})

    def test_fixed_rule_all_pass_case(self):
        row = {"active_days": 3, "n_closes": 10, "liq_hist": 0, "pnl_ext": 1.0, "avg_lev": 5.0, "wash_pair": False}
        self.assertTrue(all(item.passed for item in evaluate_rules(row)))


if __name__ == "__main__":
    unittest.main()
