# -*- coding: utf-8 -*-
"""Deterministic, explainable scoring for GroupOps entities.

Design rules (see docs/DSH_NEXT_STAGE_SPEC.md):
- Missing dimension -> None (unknown). It must never be treated as 0.
- score = 100 * sum(w_i * s_i * observed) / sum(w_i * observed); null when nothing observed.
- coverage = observed weight / total weight.
- confidence = coverage * source_quality * sample_adequacy * freshness.
- User score is computed from direct user evidence only; group score aggregates
  already-scored users (no circular re-scoring).

Everything here is pure/offline: no network, no AI, no clock reads beyond `now`.
"""
from __future__ import annotations

import datetime as _dt
import json
import math
import re

SCORE_VERSION = "v1"
PROFILE_VERSION = "v1"

USER_WEIGHTS = {
    "relevance": 0.25,
    "intent": 0.25,
    "engagement": 0.15,
    "depth": 0.15,
    "recency": 0.10,
    "reachability": 0.10,
}

GROUP_WEIGHTS = {
    "relevance": 0.25,
    "activity": 0.20,
    "demand_density": 0.20,
    "governance": 0.10,
    "fit": 0.10,
    "stability": 0.10,
    "novelty": 0.05,
}

# intent keywords -> strength (0..1). Promo/ads are risk, not value.
INTENT_RULES = [
    (re.compile(r"want_buy|wantbuy|buying|求购|收购|\bwtb\b", re.I), 1.0),
    (re.compile(r"price_check|how much|worth|price|问价|值多少", re.I), 0.9),
    (re.compile(r"complain|scam|stole|support|退款|骗", re.I), 0.7),
    (re.compile(r"opening_urge|should i open|keep going|再开", re.I), 0.6),
    (re.compile(r"showcase|unboxed|pulled|开出来了", re.I), 0.45),
]

PROMO_RE = re.compile(
    r"(?i)(my (tiktok|youtube|channel)|subscribe|check out my|promo code|affiliate|referral|join my)",
)

# Words that make a title "specific" (evidence of depth), not just chatter.
SPECIFIC_RE = re.compile(
    r"(?i)(float|0\.\d{3,}|stattrak|knife|gloves|karambit|butterfly|ak-?47|awp|m4|case|key|"
    r"trade|steam|buff|dmarket|price|usd|\$\d+)",
)

# Group name -> business relevance tokens (profile-agnostic baseline).
GROUP_TOPIC_RE = re.compile(
    r"(?i)(cs2|csgo|cs:go|counter[\s\-]?strike|skin|case|knife|trade|market|opening|unbox|"
    r"dmarket|buff|skinport|csgoroll|empire|gamble|bet)",
)

LANG_OK = {"en", "ru", "pt", "tr", "id", "es", "de", "pl", "uk", "vi", "th", "uz", "ar", "fr"}


# ---------------------------------------------------------------- helpers
def _clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))


def _num(value):
    try:
        if value is None or value == "":
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


_TIME_RE = re.compile(
    r"(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?|s|m|h|d|w|mo|y)\s*ago",
    re.I)
_UNIT_DAYS = {
    "second": 1 / 86400.0,
    "minute": 1 / 1440.0,
    "hour": 1 / 24.0,
    "day": 1.0,
    "week": 7.0,
    "month": 30.0,
    "year": 365.0,
    "d": 1,
    "day": 1,
    "days": 1,
    "h": 0.041666666666666664,
    "hr": 0.041666666666666664,
    "hour": 0.041666666666666664,
    "hours": 0.041666666666666664,
    "w": 7,
    "week": 7,
    "weeks": 7,
    "mo": 30,
    "month": 30,
    "months": 30,
    "y": 365,
    "year": 365,
    "years": 365,
    "sec": 1.1574074074074073e-05,
    "secs": 1.1574074074074073e-05,
    "s": 1.1574074074074073e-05,
    "min": 0.0006944444444444445,
    "mins": 0.0006944444444444445,
    "m": 0.0006944444444444445,
    "hr": 0.041666666666666664,
    "hrs": 0.041666666666666664,
    "h": 0.041666666666666664,
    "d": 1,
    "w": 7,
    "mo": 30,
    "y": 365,
    "year": 365,
    "years": 365,
}


def parse_age_days(text):
    """'4 days ago' -> 4.0 ; '2 months ago' -> 60.0 ; unknown -> None."""
    if not text:
        return None
    low = str(text).strip().lower()
    if low in ("just now", "now", "today", "seconds ago", "a few seconds ago"):
        return 0.0
    if low in ("yesterday", "1 day ago"):
        return 1.0
    m = _TIME_RE.search(str(text))
    if not m:
        return None
    return int(m.group(1)) * _UNIT_DAYS.get(m.group(2).lower(), 0.0)


def recency_score(days):
    """Fresh evidence counts more; hard cutoff at 180 days."""
    if days is None:
        return None
    if days <= 3:
        return 1.0
    if days >= 180:
        return 0.05
    # exponential decay, half-life ~30 days
    return _clamp(math.exp(-days / 43.0))


def weighted(dims, weights):
    """Return (score, coverage) treating None as unobserved."""
    obs_w = 0.0
    acc = 0.0
    total_w = 0.0
    for key, weight in weights.items():
        total_w += weight
        val = dims.get(key)
        if val is None:
            continue
        v = _clamp(float(val))
        acc += weight * v
        obs_w += weight
    if obs_w <= 0 or total_w <= 0:
        return None, 0.0
    return round(100.0 * acc / obs_w, 2), round(obs_w / total_w, 4)


def confidence(coverage, source_quality=1.0, sample_adequacy=1.0, freshness=1.0):
    if coverage is None or coverage <= 0:
        return 0.0
    return round(_clamp(coverage * _clamp(source_quality) * _clamp(sample_adequacy) * _clamp(freshness)), 4)


def tier(score, conf, coverage, known_dims, thresholds=None):
    """A/B/C. A requires solid evidence breadth, not one lucky dimension."""
    t = thresholds or {
        "a_score": 75.0,
        "a_conf": 0.65,
        "a_cov": 0.60,
        "a_dims": 3,
        "b_score": 45.0,
        "b_conf": 0.30,
    }
    if score is None:
        return "unknown"
    if (
        score >= t["a_score"]
        and conf >= t["a_conf"]
        and coverage >= t["a_cov"]
        and known_dims >= t["a_dims"]
    ):
        return "A"
    if score >= t["b_score"] and conf >= t["b_conf"] and known_dims >= 2:
        return "B"
    return "C"


# ---------------------------------------------------------------- user dims
def score_user(lead=None, membership=None, now=None):
    """Score one user from direct evidence.

    lead: dict-like row from leads (title, ai_relevance, intent_rule, ai_intent,
          comments, time_text, author) or None.
    membership: dict-like row from users (role, username, lang, last_active) or None.
    """
    dims = {}
    reasons = []

    if lead:
        rel = _num(lead.get("ai_relevance"))
        rule_intent = lead.get("intent_rule") or ""
        ai_intent = lead.get("ai_intent") or ""
        title = lead.get("title") or ""

        # relevance: AI relevance if scored, else topic match
        if rel is not None:
            dims["relevance"] = _clamp(rel)
            reasons.append("ai_relevance=%.2f" % rel)
        elif GROUP_TOPIC_RE.search(title):
            dims["relevance"] = 0.5
            reasons.append("topic_hit")
        else:
            dims["relevance"] = None

        # intent
        best = None
        for rx, strength in INTENT_RULES:
            if rx.search(rule_intent) or rx.search(ai_intent) or rx.search(title):
                best = max(best or 0.0, strength)
        if PROMO_RE.search(title):
            dims["intent"] = 0.1
            reasons.append("promo_signal")
        elif best is not None:
            dims["intent"] = best
            reasons.append("intent=%.2f" % best)
        else:
            dims["intent"] = None

        # engagement from comment count (log scale, 50+ saturates)
        c = _num(lead.get("comments"))
        if c is None:
            dims["engagement"] = None
        else:
            dims["engagement"] = _clamp(math.log1p(max(c, 0)) / math.log1p(50))
            reasons.append("comments=%d" % int(c))

        # depth: specific details in the title
        words = len(re.findall(r"\w+", title))
        hits = len(SPECIFIC_RE.findall(title))
        depth = None
        if words:
            depth = _clamp(0.35 * min(words / 25.0, 1.0) + 0.65 * min(hits / 3.0, 1.0))
            reasons.append("words=%d specific=%d" % (words, hits))
        dims["depth"] = depth

        # recency
        days = parse_age_days(lead.get("time_text"))
        dims["recency"] = recency_score(days)
        if days is not None:
            reasons.append("age_days=%.1f" % days)

        # reachability: public author handle present
        author = (lead.get("author") or "").strip()
        if author and author.lower() not in ("[deleted]", "automoderator"):
            dims["reachability"] = 0.8
            reasons.append("author=%s" % author[:24])
        else:
            dims["reachability"] = None

    if membership:
        lang = (membership.get("lang") or "").strip().lower()
        if lang:
            dims.setdefault("reachability", 0.6 if lang in LANG_OK else 0.2)
            reasons.append("lang=%s" % lang)
        role = (membership.get("role") or "").lower()
        if "admin" in role or "owner" in role:
            dims["depth"] = max(dims.get("depth") or 0.0, 0.7)
            reasons.append("role=admin")
        if (membership.get("username") or "").strip():
            dims["reachability"] = max(dims.get("reachability") or 0.0, 0.8)

    score, coverage = weighted(dims, USER_WEIGHTS)
    known = len([1 for v in dims.values() if v is not None])

    source_q = 0.9 if (lead and lead.get("ai_is_lead") == 1) else (0.7 if lead else 0.5)
    sample = _clamp(0.4 + 0.2 * known)  # 1 dim -> 0.6 ; 3+ -> 1.0
    fresh = dims.get("recency") if dims.get("recency") is not None else 0.6
    conf = confidence(coverage, source_q, sample, fresh) if score is not None else 0.0

    risk = []
    if lead and PROMO_RE.search(lead.get("title") or ""):
        risk.append("promo")
    if lead and (lead.get("ai_is_lead") == 0):
        risk.append("ai_rejected")

    value_type = classify_user_type(lead, membership)

    return {
        "score": score,
        "coverage": coverage,
        "confidence": conf,
        "known_dims": known,
        "dims": dims,
        "risk_flags": risk,
        "value_type": value_type,
        "reason_codes": reasons[:8],
        "tier": tier(score, conf, coverage, known),
        "score_version": SCORE_VERSION,
    }


def classify_user_type(lead, membership):
    if membership:
        role = (membership.get("role") or "").lower()
        if "admin" in role or "owner" in role:
            return "manager"
    if not lead:
        return "unknown"
    text = " ".join(str(lead.get(k) or "") for k in ("title", "intent_rule", "ai_intent"))
    if re.search(r"(?i)(want_buy|求购|wtb|how much|worth|price)", text):
        return "demand"
    if re.search(r"(?i)(sell|trade|trading|продам|vendo)", text):
        return "trader"
    if re.search(r"(?i)(unboxed|pulled|showcase|clip|video)", text):
        return "creator"
    return "unknown"


# ---------------------------------------------------------------- group dims
def _member_dict(m):
    """Accept dict rows or the fixed tuple order used by db_tool queries."""
    if isinstance(m, dict):
        return m
    try:
        uid, role, lang, uname, last = m
    except Exception:
        return {}
    return {"user_id": uid, "role": role, "lang": lang, "username": uname, "last_active": last}


def score_group(group, member_rows, user_scores, now=None):
    """Score a group from observed facts + already-computed user scores.

    group: dict-like (platform, group_name, member_count, last_member_count,
           daily_posts, status, url, lang)
    member_rows: list of dicts with keys {user_id, role, lang, username}
    user_scores: dict user_key -> {"score":..,"confidence":..}
    """
    member_rows = [_member_dict(m) for m in (member_rows or [])]
    dims = {}
    reasons = []
    name = group.get("group_name") or ""
    url = group.get("url") or ""

    # relevance: name/url topic match
    hit = bool(GROUP_TOPIC_RE.search(name) or GROUP_TOPIC_RE.search(url))
    dims["relevance"] = 0.9 if hit else 0.25
    reasons.append("topic_match" if hit else "topic_weak")

    # activity: platform reported daily posts; else member last_active coverage
    daily = _num(group.get("daily_posts"))
    active_members = [m for m in member_rows if (m.get("last_active") or "").strip()]
    if daily is not None:
        dims["activity"] = _clamp(math.log1p(daily) / math.log1p(50))
        reasons.append("daily_posts=%d" % int(daily))
    elif active_members:
        dims["activity"] = _clamp(len(active_members) / float(len(member_rows)))
        reasons.append("active_members=%d/%d" % (len(active_members), len(member_rows)))
    else:
        # 没有任何活跃信号（如 Steam 只给了 ID 列表）-> unknown，不能当 0 分惩罚
        dims["activity"] = None
        reasons.append("activity_unknown")

    # demand density: independent authors with solid scores / observed sample
    seen = set()
    scored = 0
    solid = 0
    for m in member_rows:
        uid = str(m.get("user_id") or "")
        if not uid or uid in seen:
            continue
        seen.add(uid)
        s = user_scores.get(uid)
        if not s:
            continue
        scored += 1
        if s.get("score") is not None and s.get("score") >= 55 and (s.get("confidence") or 0) >= 0.4:
            solid += 1
    observed = len(seen)
    # 分母必须是「已评分的样本」，不是全量成员，否则会人为压低密度
    if scored >= 30:
        dims["demand_density"] = _clamp(solid / float(scored) * 2.0)
        reasons.append("solid=%d scored=%d of %d" % (solid, scored, observed))
    elif scored > 0:
        dims["demand_density"] = None
        reasons.append("sample_small=%d" % scored)
    else:
        dims["demand_density"] = None
        reasons.append("no_user_sample")

    # governance: admin presence, member count sanity
    admins = [m for m in member_rows if "admin" in (m.get("role") or "").lower()]
    if member_rows:
        dims["governance"] = _clamp(0.3 + 0.7 * min(len(admins) / 2.0, 1.0))
        reasons.append("admins=%d" % len(admins))
    else:
        dims["governance"] = None

    # fit: language + joinability
    lang = (group.get("lang") or "").strip().lower()
    status = (group.get("status") or "").strip()
    fit = 0.0
    if lang and lang in LANG_OK:
        fit += 0.5
    if status in ("已加入", "公开群", "公开"):
        fit += 0.5
    dims["fit"] = _clamp(fit) if (lang or status) else None

    # stability: member count trend
    cur = _num(group.get("member_count"))
    prev = _num(group.get("last_member_count"))
    if cur is not None and prev is not None and prev > 0:
        delta = (cur - prev) / float(prev)
        dims["stability"] = _clamp(1.0 - abs(delta) * 2.0)
        reasons.append("delta=%.3f" % delta)
    elif cur is not None and cur > 0:
        dims["stability"] = 0.6
        reasons.append("first_snapshot")
    else:
        dims["stability"] = None

    # novelty: unknown without overlap computation
    dims["novelty"] = None

    score, coverage = weighted(dims, GROUP_WEIGHTS)
    known = len([1 for v in dims.values() if v is not None])

    source_q = 0.8 if len(member_rows) >= 30 else (0.6 if member_rows else 0.5)
    sample = _clamp(0.35 + 0.15 * known + (0.2 if observed >= 30 else 0.0))
    fresh = 0.8 if (group.get("status") or "") == "已加入" else 0.6
    conf = confidence(coverage, source_q, sample, fresh) if score is not None else 0.0

    risk = []
    big = cur or 0
    if big >= 100000 and scored < 30:
        risk.append("huge_untested")
    if scored >= 30 and solid / float(max(scored, 1)) > 0.9:
        risk.append("suspicious_density")

    return {
        "score": score,
        "coverage": coverage,
        "confidence": conf,
        "known_dims": known,
        "dims": dims,
        "risk_flags": risk,
        "reason_codes": reasons[:8],
        "tier": tier(score, conf, coverage, known),
        "observed_members": observed,
        "scored_members": scored,
        "score_version": SCORE_VERSION,
    }


# ---------------------------------------------------------------- recommendations
def dedupe_key(action_type, platform, native_id, window="d7"):
    return "%s:%s:%s:%s:%s" % (action_type, platform, native_id, PROFILE_VERSION, window)


def build_recommendations(group_scores, eligibility=None, limit=50):
    """Deterministic suggestion list. Eligibility gates are applied by caller."""
    eligibility = eligibility or {}
    out = []
    for (platform, gid), s in group_scores.items():
        if s.get("score") is None:
            continue
        elig = eligibility.get((platform, gid), {})
        if elig.get("joined") or elig.get("blocked") or elig.get("quota_zero"):
            continue
        score, conf = s["score"], s["confidence"]
        if score >= 70 and conf >= 0.6:
            action = "recommend_join"
        elif score >= 50 and conf < 0.6:
            action = "validate_group"
        elif conf < 0.35:
            action = "sample_group"
        else:
            continue
        out.append(
            {
                "action_type": action,
                "platform": platform,
                "entity_id": gid,
                "score": score,
                "confidence": conf,
                "coverage": s["coverage"],
                "reason_codes": s.get("reason_codes", []),
                "dedupe_key": dedupe_key(action, platform, gid),
            }
        )
    out.sort(key=lambda r: (-(r["score"] * r["confidence"]), r["entity_id"]))
    return out[:limit]


# ---------------------------------------------------------------- config io
DEFAULT_CONFIG = {
    "score_version": SCORE_VERSION,
    "profile_version": PROFILE_VERSION,
    "user_weights": USER_WEIGHTS,
    "group_weights": GROUP_WEIGHTS,
    "thresholds": {"a_score": 75.0, "a_conf": 0.65, "a_cov": 0.60, "a_dims": 3, "b_score": 45.0, "b_conf": 0.30},
}


def load_config(path=None):
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if path:
        try:
            with open(path, "r", encoding="utf-8-sig") as fh:
                user = json.load(fh)
            for k, v in (user or {}).items():
                if k in ("user_weights", "group_weights", "thresholds") and isinstance(v, dict):
                    cfg[k].update(v)
                else:
                    cfg[k] = v
        except FileNotFoundError:
            pass
        except Exception:
            pass
    return cfg


def now_iso():
    return _dt.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


# ---------------------------------------------------------------- topic dims
TOPIC_WEIGHTS = {
    "volume": 0.20,
    "demand": 0.35,
    "freshness": 0.20,
    "diversity": 0.15,
    "specificity": 0.10,
}


def score_topic(keyword, rows, now=None):
    """rows: list of leads dicts (author, ai_relevance, intent_rule, ai_intent,
    comments, time_text, title). Topic value = 需求密度 × 新鲜度 × 作者多样性。
    """
    rows = [r for r in rows if r]
    n = len(rows)
    if n == 0:
        return None

    authors = set((r.get("author") or "").strip().lower() for r in rows)
    authors.discard("")
    authors.discard("[deleted]")

    # volume: log scale, 40 signals saturates
    dims = {"volume": _clamp(math.log1p(n) / math.log1p(40))}

    # demand: share of rows that look like a real need (not showcase/promo)
    strong = 0
    for r in rows:
        text = " ".join(str(r.get(k) or "") for k in ("intent_rule", "ai_intent", "title"))
        if PROMO_RE.search(text):
            continue
        best = 0.0
        for rx, strength in INTENT_RULES:
            if rx.search(text):
                best = max(best, strength)
        if best >= 0.6:
            strong += 1
    dims["demand"] = _clamp(strong / float(n))

    # freshness: median age
    ages = [parse_age_days(r.get("time_text")) for r in rows]
    ages = [a for a in ages if a is not None]
    dims["freshness"] = recency_score(sorted(ages)[len(ages) // 2]) if ages else None

    # diversity: independent authors, capped at 8
    dims["diversity"] = _clamp(len(authors) / 8.0) if authors else 0.0

    # specificity: how many rows carry concrete product/price detail
    spec = sum(1 for r in rows if SPECIFIC_RE.search(str(r.get("title") or "")))
    dims["specificity"] = _clamp(spec / float(n))

    score, coverage = weighted(dims, TOPIC_WEIGHTS)
    known = len([1 for v in dims.values() if v is not None])
    source_q = 0.8 if n >= 10 else 0.6
    sample = _clamp(0.3 + 0.1 * min(n, 8) / 8.0 * 7)  # 1 signal -> 0.39 ; 8+ -> 1.0
    fresh = dims.get("freshness") if dims.get("freshness") is not None else 0.5
    conf = confidence(coverage, source_q, min(sample, 1.0), fresh) if score is not None else 0.0

    risk = []
    if authors and len(authors) <= 1 and n >= 3:
        risk.append("single_author_spam")

    return {
        "score": score,
        "coverage": coverage,
        "confidence": conf,
        "known_dims": known,
        "dims": dims,
        "risk_flags": risk,
        "reason_codes": ["signals=%d" % n, "authors=%d" % len(authors), "strong=%d" % strong],
        "tier": tier(score, conf, coverage, known),
        "score_version": SCORE_VERSION,
    }


def priority_of(score, conf, dims):
    """Sort key: value × confidence, with a penalty when demand is unobserved.

    Keeps giant-but-untested groups from outranking evidence-rich small ones.
    """
    if score is None:
        return -1.0
    base = (score or 0.0) * (conf or 0.0)
    if (dims or {}).get("demand_density") is None:
        base *= 0.55
    if (dims or {}).get("activity") is None:
        base *= 0.8
    return base


def build_topic_recommendations(topic_scores, limit=20):
    out = []
    for kw, s in topic_scores.items():
        if s.get("score") is None:
            continue
        if s["score"] >= 55 and s["confidence"] >= 0.35 and "single_author_spam" not in (s.get("risk_flags") or []):
            out.append({
                "action_type": "suggest_query",
                "platform": "Reddit",
                "entity_id": kw,
                "score": s["score"],
                "confidence": s["confidence"],
                "coverage": s["coverage"],
                "reason_codes": s.get("reason_codes", []),
                "dedupe_key": dedupe_key("suggest_query", "Reddit", kw),
            })
    out.sort(key=lambda r: (-(r["score"] * r["confidence"]), r["entity_id"]))
    return out[:limit]
