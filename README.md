# Surety Market Intelligence

A live dashboard for tracking surety-relevant industry news and top-account risk signals, built for surety industry underwriting use. Automated news discovery and analysis is handled by Claude; this repo currently hosts the front-end dashboard, with the goal of eventually managing the full pipeline (site + automation config) from here.

**Live site:** https://richiebuchanan.github.io/SuretyMarketIntelligence/

## What this is

A single-page dashboard that reads live from a Supabase database and shows:

- **Article ledger** — surety and construction-industry news, each scored 1–10 for underwriting relevance, with category (Contract Surety / Commercial Surety / Both / General), region, source, and a short AI-generated summary and underwriter insight per article. Filterable by category, region, source, company, date range, priority score, and free-text search.
- **6-Week Market Analysis** — a periodically-refreshed executive summary (key themes, critical risks, underwriting implications) synthesized from the recent article set, with every claim cited back to a specific article.
- **Company tagging** — articles are tagged with the real company/companies they're about (not limited to any fixed list), so news on a specific account can be isolated via the Company filter.

All data — articles, the market analysis, and the tracked-company list — lives in Supabase and updates automatically. There is nothing to redeploy when new data comes in; only actual design or code changes to the page require a new commit here.

## Architecture

```
┌─────────────────────┐
│  Claude (scheduled   │  Runs daily at 10:00 UTC. Searches for new
│  task, once daily)   │  industry news and news on watchlist companies,
└──────────┬───────────┘  scores each article, writes into Supabase.
           │
           ▼
┌─────────────────────┐
│      Supabase        │  Postgres database + REST API (PostgREST).
│  (acxdvzcohjayvmqdaoke)│  3 of 5 tables are public read-only (anon key,
└──────────┬───────────┘  no auth); 2 back-office tables are locked down
           │              entirely — see "Supabase schema" below.
           │  (browser reads directly, client-side, on page load
           │   and every 60s thereafter)
           ▼
┌─────────────────────┐
│   index.html          │  This repo. Static HTML/CSS/JS, no build
│  (GitHub Pages)       │  step. Fetches from Supabase using the
└───────────────────────┘  public anon key (safe — table access is
                            read-only via Row Level Security).
```

**Why GitHub Pages, not Netlify or Supabase Edge Functions:** both were tried first. Netlify's deploy credential kept failing with an unrecovered 403. Supabase Edge Functions turned out to have an undocumented platform restriction — `GET` requests returning `text/html` are silently rewritten to `text/plain` on their default domain, so HTML can't be served from a Supabase Function without a paid custom domain. GitHub Pages has no such restriction and is free.

## Supabase schema (project `acxdvzcohjayvmqdaoke`)

Five tables total. Full column-by-column DDL, including the exact RLS
policies, lives in [`schema.sql`](./schema.sql) — this section is the quick
reference.

**Public read-only** (anon/authenticated `SELECT`, nothing else — all writes happen through the scheduled task's own Supabase connection or by running SQL directly, never through the site):

### `surety_articles`
The main article ledger. Append-only — rows are never updated or deleted, deduplicated on `link` (unique constraint).

| column | type | notes |
|---|---|---|
| `date_found` | date | when the article was discovered |
| `article_title` | text | |
| `link` | text | unique — dedup key |
| `source_site` | text | e.g. "Construction Dive" |
| `source_publish_date` | date | |
| `region` | text | e.g. "Northeast (New York)" or "National" |
| `relevance_category` | text | `Contract Surety` \| `Commercial Surety` \| `Both` \| `General` (convention, not DB-enforced — see `schema.sql`) |
| `underwriter_value_score` | smallint | 1–10 |
| `score_rationale` | text | one sentence |
| `summary` | text | 2–4 sentences |
| `bullet_points` | text | `"- "`-prefixed lines |
| `underwriter_insights` | text | |
| `flagged_by_user` | boolean | true if submitted via the article queue rather than discovered |
| `related_account` | text[] | real company name(s) the article is about; `NULL` for general industry articles |

### `market_analysis`
| column | type | notes |
|---|---|---|
| `analysis_date` | date | |
| `analysis` | jsonb | `{period_label, article_count, executive_summary, key_themes[], critical_risks[], underwriting_implications[]}`, each list item citing back to article ids |

The dashboard always shows the single most recent row.

### `account_watchlist`
| column | type | notes |
|---|---|---|
| `company_name` | text | unique |

The list of companies the daily task specifically searches news for (in addition to general industry search). Currently 98 companies. Not the same as `related_account` on `surety_articles` — articles can be tagged with any real company, watchlist or not; this table only drives which companies get a dedicated daily search pass.

**Back-office only** (RLS enabled, *zero* policies — invisible to the public anon key, read/written only via direct SQL or the scheduled task's own connection):

### `surety_article_queue`
| column | type | notes |
|---|---|---|
| `link` | text | manually flagged link to force into the next run |
| `notes` | text | optional context for why it was flagged |
| `processed` | boolean | set once a run has handled it |
| `processed_at` | timestamptz | |

A Postgres table, not a Google Sheet — rows go in via direct SQL today. Anything in here gets processed on the next run regardless of newsworthiness. Never deleted — it doubles as a submission history.

### `target_trade_publications`
| column | type | notes |
|---|---|---|
| `site_name` | text | |
| `listing_url` | text | unique — RSS feed or HTML listing page |
| `source_type` | text | `RSS` \| `HTML_LISTING` |
| `notes` | text | operational notes the automation reads and follows (dead feed paths, staleness quirks, etc.) |
| `active` | boolean | |

The standing list of trade-press sites fetched every run — currently 13 (10 RSS, 3 scraped listing pages). The automation *suggests* new candidates in its run summary when it stumbles on an on-beat source not yet in this table, but never adds one itself; someone has to approve the INSERT.

## The daily automation

A Claude scheduled task (configured in Claude's Tasks/Routines settings, cron `0 10 * * *` — not yet version-controlled as a repo file, though its exact current text is mirrored in [`AUTOMATION.md`](./AUTOMATION.md) for reference) runs once a day and:
1. Processes any manually-flagged links from the `surety_article_queue` table
2. Checks the 13-site trade-press list directly, then searches general business press (CNBC, Bloomberg) for anything else surety-relevant
3. Searches for news on each of the ~98 companies in `account_watchlist`
4. Scores, classifies, and tags every new article, inserting into `surety_articles`
5. Flags (but doesn't add) any promising new trade-pub sources for review
6. Regenerates the `market_analysis` row from the last 6 weeks of articles, with inline citations

**See [`AUTOMATION.md`](./AUTOMATION.md)** for a full walkthrough of how and why each step works the way it does, the design decisions behind the schema, and a generalized recipe for pointing this same pattern at a different topic.

## Updating the dashboard

There's no build step — `index.html` is the whole deployable artifact. To make a change:

1. Edit `index.html` (or hand the file to Claude to make the change and return an updated copy)
2. Commit the updated file to `main` — GitHub Pages auto-redeploys within a minute or two
3. No changes here are needed for new data — that flows in automatically via Supabase

## Roadmap

- [ ] Bring the scheduled-task configuration into this repo as a tracked file (currently lives only in Claude's Tasks UI — `AUTOMATION.md` is a manually-kept mirror of it, so it can drift)
- [ ] Consider GitHub Actions for deploy automation as the codebase grows beyond a single HTML file
- [ ] Add DB-level `CHECK` constraints for `relevance_category` and `underwriter_value_score` (currently prompt-enforced only — see `schema.sql`)
- [ ] `account_watchlist` is at 98 of the target ~100 top accounts — close it out
