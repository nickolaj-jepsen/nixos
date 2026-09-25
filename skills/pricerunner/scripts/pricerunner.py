#!/usr/bin/env python3
"""Query PriceRunner.dk through its unofficial frontend JSON API.

Stdlib only. Every command prints compact JSON to stdout; errors go to stderr
with exit code 1. See ../SKILL.md for the workflow and filter syntax.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://www.pricerunner.dk"
API = f"{BASE}/dk/api"
CC = "DK"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130 Safari/537.36"
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "pricerunner")
MENU_TTL = 7 * 86400


def get(service, path, params=None):
    url = f"{API}/{service}{path}"
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(
            {k: v for k, v in params.items() if v not in (None, "")}, safe=",_-"
        )
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} for {url}")
    return json.loads(body) if body else {}


def out(data):
    json.dump(data, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def filters(pairs):
    """`-f BRAND=162,120258 -f PRICE=_1500` -> {"af_BRAND": "162,120258", "af_PRICE": "_1500"}."""
    res = {}
    for p in pairs or []:
        k, sep, v = p.partition("=")
        if not sep:
            sys.exit(f"bad filter {p!r}, expected ID=VALUE")
        k = k.strip()
        res[k if k.startswith("af_") else f"af_{k}"] = v.strip()
    return res


def product_id(s):
    """Accept 3216399795, 94-3216399795 or a /pl/ URL; return (category_id|None, product_id)."""
    m = re.search(r"(?:/pl/)?(?:(\d+)-)?(\d{5,})", s)
    if not m:
        sys.exit(f"can't parse product id from {s!r}")
    return m.group(1), m.group(2)


def money(p):
    return float(p["amount"]) if p and p.get("amount") else None


def slim_product(p):
    drop = p.get("priceDrop") or {}
    rating = p.get("rating") or {}
    cat = p.get("category") or {}
    return {
        k: v
        for k, v in {
            "id": p.get("id"),
            "name": p.get("name"),
            "price": money(p.get("lowestPrice")),
            "oldPrice": money(drop.get("oldPrice")),
            "dropPct": float(drop["percent"]) if drop.get("percent") else None,
            "category": cat.get("name"),
            "categoryId": (cat.get("id") or "").removeprefix("cl") or None,
            "desc": p.get("description"),
            "rating": float(rating["average"]) if rating.get("count") else None,
            "ratings": rating.get("count") or None,
            "merchants": (p.get("previewMerchants") or {}).get("count"),
            "outOfStock": p.get("outOfStock") or None,
            "url": BASE + p["url"] if p.get("url") else None,
        }.items()
        if v not in (None, "")
    }


def slim_quickfilters(qfs):
    return [
        {
            "id": q["id"],
            "name": q["name"],
            "type": q.get("type"),
            "unit": q.get("unit"),
            "options": [
                {"id": o["id"], "value": o["value"]}
                | ({"from": o["from"], "to": o["to"]} if o.get("from") or o.get("to") else {})
                for o in q.get("options", [])
            ],
        }
        for q in qfs or []
    ]


def cmd_search(a):
    params = {"q": a.query, **filters(a.filter)}
    if a.category:
        params["af_CATEGORY"] = a.category if "-" in a.category else f"cl{a.category.removeprefix('cl')}"
    if a.no_extract:
        params["filterExtraction"] = "false"
    if a.offset:
        params |= {"offset": a.offset, "size": a.limit}
        d = get("search-edge-rest", f"/public/search/v6/products/{CC}", params)
        return out({"total": d.get("totalHits"), "products": [slim_product(p) for p in d["products"]]})
    d = get("search-edge-rest", f"/public/search/v6/{CC}", params | {"facetsSize": 10})
    out(
        {
            "total": d["numberOfHits"]["product"],
            "appliedParams": d.get("queryParams"),
            "applied": [
                {"id": f["id"], "name": f["name"], "options": f.get("options"), "range": f.get("range")}
                for f in ((d.get("applied") or {}).get("filters") or {}).get("filters", [])
            ],
            "spelling": d.get("spellingSuggestion"),
            "products": [slim_product(p) for p in d["products"][: a.limit]],
            "facets": slim_quickfilters(d.get("quickFilters")),
        }
    )


def menu():
    path = os.path.join(CACHE, f"menu-{CC}.json")
    try:
        if time.time() - os.path.getmtime(path) < MENU_TTL:
            with open(path) as f:
                return json.load(f)
    except OSError:
        pass
    d = get("seo-edge-rest", f"/public/navigation/menu/{CC}")
    os.makedirs(CACHE, exist_ok=True)
    with open(path, "w") as f:
        json.dump(d, f, ensure_ascii=False)
    return d


def flat_categories():
    """Flatten the mega menu into {id, name, kind, parents[, cl]} rows.

    kind: "tree" (t<id>, grouping only), "cl" (category for list/filters/facets
    and `search -c`), "sub" (narrows parent `cl`: `list <cl> --sub` or `search -c`).
    """
    rows = []

    def walk(node, parents, parent_cl):
        nid = node["id"]
        if nid.startswith("t"):
            kind, cid = "tree", nid
        elif nid.startswith("cl"):
            kind, cid = "cl", nid[2:]
        else:
            kind, cid = "sub", nid
        row = {"id": cid, "name": node["name"], "kind": kind, "parents": " > ".join(parents)}
        if kind == "sub":
            row["cl"] = parent_cl
        rows.append(row)
        for c in (node.get("categories") or []) + (node.get("children") or []):
            walk(c, parents + [node["name"]], cid if kind == "cl" else parent_cl)

    for top in menu()["categories"]:
        walk(top["hierarchy"], [], None)
    return rows


def cmd_categories(a):
    rows = flat_categories()
    if a.grep:
        rx = re.compile(a.grep, re.I)
        rows = [r for r in rows if rx.search(r["name"]) or rx.search(r["parents"])]
    if a.kind:
        rows = [r for r in rows if r["kind"] == a.kind]
    out(rows)


def cmd_filters(a):
    d = get("search-edge-rest", f"/public/search/category/filters/{CC}/{a.category}", {"showAll": "true", **filters(a.filter)})
    seen, res = set(), []
    for g in d.get("groups", []):
        for f in g["filters"]:
            if f["id"] not in seen:
                seen.add(f["id"])
                res.append({"id": f["id"], "name": f["name"], "type": f["type"], "unit": f.get("unit"), "group": g["name"]})
    out(res)


def cmd_facets(a):
    params = {"ids": ",".join(a.ids), **filters(a.filter)}
    d = get("search-edge-rest", f"/public/search/category/facets/{CC}/{a.category}/", params)
    res = []
    for fid, v in d["facets"].items():
        f = v["facet"]
        item = {"id": fid, "name": f.get("name"), "unit": f.get("unit")}
        buckets = f.get("options") or f.get("counts") or []
        if buckets and "optionId" in buckets[0]:
            opts = [{"id": str(o["optionId"]), "value": o["optionValue"], "count": o["count"]} for o in buckets]
            if a.grep:
                opts = [o for o in opts if re.search(a.grep, o["value"], re.I)]
            item["options"] = sorted(opts, key=lambda o: -o["count"])[: a.limit]
        else:
            item |= {"min": f.get("minimum"), "max": f.get("maximum"), "buckets": buckets}
        res.append(item)
    out(res)


def cmd_list(a):
    params = {"size": a.limit, "offset": a.offset or None, "sorting": a.sort, **filters(a.filter)}
    if a.query:
        params["q"] = a.query
    if a.sub:
        attr, _, opt = a.sub.partition("-")
        params[f"af_{attr}"] = opt
    d = get("search-edge-rest", f"/public/search/category/v4/{CC}/{a.category}", params | {"device": "desktop"})
    cat = d.get("category") or {}
    out(
        {
            "category": {"id": cat.get("id"), "name": cat.get("name"), "path": " > ".join(p["name"] for p in cat.get("path", []))},
            "subcategories": [
                {"sub": c["id"], "name": c["name"], "count": c.get("productCount")} for c in cat.get("children", [])
            ],
            "total": d.get("totalProductHits"),
            "products": [slim_product(p) for p in d.get("products", [])],
            "quickFilters": slim_quickfilters(d.get("quickFilters")),
        }
    )


def cmd_offers(a):
    _, pid = product_id(a.product)
    params = {
        "af_ORIGIN": None if a.international else "NATIONAL",
        "af_ITEM_CONDITION": "NEW,UNKNOWN" if not a.used else None,
        "af_STOCK_STATUS": None if a.all_stock else "IN_STOCK,BACKORDER,PREORDER,SPECIAL_ORDER,COLLECT_IN_STORE",
        "sortByPreset": "PRICE_WITH_SHIPPING" if a.sort == "total" else "PRICE",
        "languageCode": "da",
    }
    d = get("product-detail-edge-rest", f"/public/product-detail/v0/offers/{CC}/{pid}", params)
    merchants = d.get("merchants") or {}
    offers = []
    for o in d.get("offers", [])[: a.limit]:
        m = merchants.get(o["merchantId"], {})
        price, ship = money(o.get("price")), money(o.get("shippingCost"))
        offers.append(
            {
                k: v
                for k, v in {
                    "merchant": m.get("name"),
                    "merchantId": o["merchantId"],
                    "price": price,
                    "shipping": ship,
                    "total": round(price + ship, 2) if price is not None and ship is not None else None,
                    "stock": o.get("stockStatus"),
                    "delivery": o.get("deliveryTime"),
                    "country": m.get("internationalCountryCode"),
                    "merchantRating": (m.get("rating") or {}).get("averageRating"),
                    "offerName": o.get("name"),
                    "labels": (o.get("labels") or {}).get("propertyLabels") or None,
                    "url": o.get("url"),
                }.items()
                if v not in (None, "", [])
            }
        )
    out({"productId": pid, "summary": d.get("offersSummary"), "offers": offers})


def cmd_history(a):
    _, pid = product_id(a.product)
    d = get(
        "product-information-edge-rest",
        f"/public/pricehistory/product/{pid}/{CC}/DAY",
        {"merchantId": a.merchant or "", "selectedInterval": a.interval, "filter": "NATIONAL"},
    )
    hist = d.get("history") or []
    if not hist:
        return out({"productId": pid, "history": []})
    lowest = min(hist, key=lambda h: h["price"])
    highest = max(hist, key=lambda h: h["price"])
    cur = hist[-1]["price"]
    prices = sorted(h["price"] for h in hist)
    step = max(1, len(hist) // a.points)
    out(
        {
            "productId": pid,
            "interval": a.interval,
            "current": cur,
            "lowest": {"price": lowest["price"], "date": lowest["timestamp"][:10], "merchant": lowest.get("merchantName")},
            "highest": {"price": highest["price"], "date": highest["timestamp"][:10]},
            "median": prices[len(prices) // 2],
            "currentPercentile": round(100 * sum(p < cur for p in prices) / len(prices)),
            "series": [[h["timestamp"][:10], h["price"], h.get("merchantName")] for h in hist[::step]]
            + ([[hist[-1]["timestamp"][:10], cur, hist[-1].get("merchantName")]] if (len(hist) - 1) % step else []),
        }
    )


def cmd_info(a):
    _, pid = product_id(a.product)
    d = get("product-information-edge-rest", f"/public/info/product/{CC}", {"productIds": pid})
    info = (d.get("productInfoSet") or [{}])[0]
    r = get("review-edge-rest", f"/public/v2/products/reviews/overview/{CC}/{pid}/") or {}
    out(
        {
            "name": info.get("productName"),
            "url": BASE + info["productUrl"] if info.get("productUrl") else None,
            "lowest": {k: {"price": v["price"], "merchantId": v["merchantId"]} for k, v in (info.get("offerPrices") or {}).items() if v},
            "reviews": {
                k: r.get(k)
                for k in ("score", "scoreCount", "userReviewCount", "proReviewCount", "userScoreDistribution")
            }
            | {
                "proReviews": [
                    {k: p.get(k) for k in ("source", "score", "scoreMax", "title", "pros", "cons", "link")}
                    for p in ((r.get("proReviews") or {}).get("reviews") or [])
                ]
            },
        }
    )


def cmd_similar(a):
    cat, pid = product_id(a.product)
    if not cat:
        info = get("product-information-edge-rest", f"/public/info/product/{CC}", {"productIds": pid})
        cat, _ = product_id((info.get("productInfoSet") or [{}])[0].get("productUrl", ""))
    d = get("similar-edge-rest", f"/public/search/products/similar/{CC}/{cat}/{pid}", {"size": a.limit})
    out([slim_product(p) for p in d.get("products", [])])


def cmd_compare(a):
    ids = ",".join(product_id(p)[1] for p in a.products)
    d = get("similar-edge-rest", f"/public/search/compare/v2/{CC}", {"productIds": ids})
    names = {p["id"]: p["name"] for p in d.get("products", [])}
    specs = {}
    for c in d.get("categories", []):
        for g in c.get("attributeGroups", []):
            for at in g.get("attributes", []):
                vals = {names.get(pid, pid): ", ".join(v) + (f" {at['unit']}" if at.get("unit") else "") for pid, v in at["values"].items()}
                if a.all or len(set(vals.values())) > 1 or len(vals) < len(names):
                    specs[f"{g.get('name')} / {at['name']}"] = vals
    out({"products": [slim_product(p) for p in d.get("products", [])], "specs": specs})


def cmd_deals(a):
    params = {
        "af_PRICE_DROP": f"-90_-{a.min_drop}",
        "size": a.limit,
        "offset": a.offset or None,
        "sorting": a.sort,
        **filters(a.filter),
    }
    if a.category:
        params["af_CATEGORY"] = a.category
    d = get("deals-edge-rest", f"/public/search/deals/products/v3/{CC}", params)
    out({"total": d.get("totalHits"), "products": [slim_product(p) for p in d.get("products", [])]})


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    fhelp = "facet filter ID=VALUE, repeatable (BRAND=162,4317 | PRICE=500_1500 | RATING=4_ | ONLY_IN_STOCK=true)"

    s = sub.add_parser("search", help="free-text product search with facets")
    s.add_argument("query")
    s.add_argument("-f", "--filter", action="append", help=fhelp)
    s.add_argument("-c", "--category", help="restrict to a cl id (94) or sub id (100003567-100014541)")
    s.add_argument("-n", "--limit", type=int, default=20)
    s.add_argument("--offset", type=int, help="page past the first result set (drops facets)")
    s.add_argument("--no-extract", action="store_true", help="don't let PriceRunner turn query words into filters")
    s.set_defaults(fn=cmd_search)

    s = sub.add_parser("categories", help="category tree (cached 7 days)")
    s.add_argument("grep", nargs="?", help="regex on name or parent path")
    s.add_argument("--kind", choices=["tree", "cl", "sub"])
    s.set_defaults(fn=cmd_categories)

    s = sub.add_parser("filters", help="filter ids available in a category")
    s.add_argument("category")
    s.add_argument("-f", "--filter", action="append", help=fhelp)
    s.set_defaults(fn=cmd_filters)

    s = sub.add_parser("facets", help="option ids + counts for filters in a category")
    s.add_argument("category")
    s.add_argument("ids", nargs="+", help="filter ids from `filters`, e.g. BRAND 59671607")
    s.add_argument("-f", "--filter", action="append", help=fhelp)
    s.add_argument("-g", "--grep", help="regex on option value")
    s.add_argument("-n", "--limit", type=int, default=40)
    s.set_defaults(fn=cmd_facets)

    s = sub.add_parser("list", help="browse a category with filters and sorting")
    s.add_argument("category")
    s.add_argument("-q", "--query")
    s.add_argument("--sub", help="subcategory id from `categories`/`subcategories`, e.g. 100003567-100014541")
    s.add_argument("-f", "--filter", action="append", help=fhelp)
    s.add_argument("-s", "--sort", choices=["POPULARITY", "PRICE_ASC", "PRICE_DESC", "NAME", "PRICE_DROP", "RATING", "TREND"])
    s.add_argument("-n", "--limit", type=int, default=24)
    s.add_argument("--offset", type=int)
    s.set_defaults(fn=cmd_list)

    s = sub.add_parser("offers", help="shop offers for a product")
    s.add_argument("product", help="id, <cat>-<id> or /pl/ URL")
    s.add_argument("-n", "--limit", type=int, default=15)
    s.add_argument("--sort", choices=["total", "price"], default="total", help="total = incl. shipping")
    s.add_argument("--international", action="store_true", help="include foreign shops")
    s.add_argument("--used", action="store_true", help="include used/refurbished")
    s.add_argument("--all-stock", action="store_true", help="include out-of-stock offers")
    s.set_defaults(fn=cmd_offers)

    s = sub.add_parser("history", help="daily lowest-price history")
    s.add_argument("product")
    s.add_argument(
        "-i", "--interval", default="ONE_YEAR",
        choices=["ONE_WEEK", "ONE_MONTH", "THREE_MONTHS", "ONE_YEAR", "TWO_YEARS", "INFINITE_DAYS"],
    )
    s.add_argument("-m", "--merchant", help="merchant id")
    s.add_argument("-p", "--points", type=int, default=30, help="max series points")
    s.set_defaults(fn=cmd_history)

    s = sub.add_parser("info", help="lowest national/international price + review scores")
    s.add_argument("product")
    s.set_defaults(fn=cmd_info)

    s = sub.add_parser("similar", help="similar products")
    s.add_argument("product")
    s.add_argument("-n", "--limit", type=int, default=7)
    s.set_defaults(fn=cmd_similar)

    s = sub.add_parser("compare", help="spec-by-spec comparison of products")
    s.add_argument("products", nargs="+")
    s.add_argument("--all", action="store_true", help="include specs that are identical across products")
    s.set_defaults(fn=cmd_compare)

    s = sub.add_parser("deals", help="current price drops")
    s.add_argument("-c", "--category", help="cl id, e.g. 94")
    s.add_argument("--min-drop", type=int, default=10, help="minimum drop in percent")
    s.add_argument("-f", "--filter", action="append", help=fhelp)
    s.add_argument(
        "-s", "--sort", default="PRICEDROP_ASC",
        choices=["PRICEDROP_ASC", "LATESTPRICEDROPTIME_DESC", "GLOBALRANK_ASC", "PRICE_ASC", "PRICE_DESC"],
    )
    s.add_argument("-n", "--limit", type=int, default=20)
    s.add_argument("--offset", type=int)
    s.set_defaults(fn=cmd_deals)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
