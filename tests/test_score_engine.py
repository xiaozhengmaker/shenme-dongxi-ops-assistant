# -*- coding: utf-8 -*-
"""离线评分引擎单测：只依赖 score_engine，不联网、不读库。"""
import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "score_engine", Path(__file__).resolve().parents[1] / "score_engine.py")
se = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(se)


def _lead(author="a1", title="wtb ak redline", time_text="2 days ago", intent="want_buy", rel=0.8):
    return {"author": author, "title": title, "time_text": time_text,
            "intent_rule": intent, "ai_intent": intent, "ai_relevance": rel, "comments": 3}


class ScoreEngineTests(unittest.TestCase):
    def test_missing_dimension_not_penalised(self):
        """未观察维度不进分母：只有 2 个已知维度时按这两个维度归一。"""
        dims = {"relevance": 0.8, "governance": 0.4}
        score, cov = se.weighted(dims, se.GROUP_WEIGHTS)
        self.assertAlmostEqual(cov, 0.35, places=4)
        self.assertAlmostEqual(score, 100.0 * (0.25 * 0.8 + 0.10 * 0.4) / 0.35, delta=0.02)
        self.assertGreater(score, 55)

    def test_huge_group_without_sample_cannot_be_tier_a(self):
        dims = {"relevance": 0.9, "activity": None, "demand_density": None,
                "governance": 0.3, "fit": None, "stability": 0.6, "novelty": None}
        score, cov = se.weighted(dims, se.GROUP_WEIGHTS)
        conf = se.confidence(cov, 0.8, 0.3, 0.5)
        known = len([v for v in dims.values() if v is not None])
        self.assertIn(se.tier(score, conf, cov, known), ("C", "D"))

    def test_single_author_spam_flagged_and_no_recommendation(self):
        rows = [_lead(author="spammer") for _ in range(8)]
        r = se.score_topic("keys", rows)
        self.assertIn("single_author_spam", r["risk_flags"] or [])
        self.assertEqual(se.build_topic_recommendations({"keys": r}), [])

    def test_showcase_is_not_demand(self):
        showcase = [_lead(author="u%d" % i, title="unboxed a knife", intent="showcase") for i in range(10)]
        want = [_lead(author="v%d" % i, title="wtb ak redline paying keys", intent="want_buy") for i in range(10)]
        a = se.score_topic("unboxed", showcase)
        b = se.score_topic("trade", want)
        self.assertLess(a["dims"]["demand"], 0.3)
        self.assertGreater(b["dims"]["demand"], 0.9)
        self.assertGreater(b["score"], a["score"])

    def test_cross_platform_never_merged(self):
        a = se.dedupe_key("join", "Telegram", "123")
        b = se.dedupe_key("join", "Discord", "123")
        self.assertNotEqual(a, b)
        self.assertEqual(a, se.dedupe_key("join", "Telegram", "123"))

    def test_big_ids_preserved(self):
        uid = "1234567890123456789"
        self.assertIn(uid, se.dedupe_key("contact", "Discord", uid))

    def test_priority_penalises_unobserved_demand(self):
        hot_small = se.priority_of(60.0, 0.5, {"demand_density": 0.8, "activity": 0.7})
        big_unknown = se.priority_of(70.0, 0.5, {"demand_density": None, "activity": None})
        self.assertGreater(hot_small, big_unknown)

    def test_tier_requires_confidence_not_just_score(self):
        self.assertIn(se.tier(95.0, 0.2, 0.9, 6), ("C", "D"))
        self.assertEqual(se.tier(80.0, 0.7, 0.7, 4), "A")

    def test_age_parser_handles_units(self):
        self.assertEqual(se.parse_age_days("4 days ago"), 4)
        self.assertGreater(se.parse_age_days("3 months ago"), 80)
        self.assertEqual(se.parse_age_days("just now"), 0)
        self.assertEqual(se.parse_age_days("yesterday"), 1)
        self.assertIsNotNone(se.parse_age_days("2 d ago"))
        self.assertIsNone(se.parse_age_days(""))


if __name__ == "__main__":
    unittest.main()
