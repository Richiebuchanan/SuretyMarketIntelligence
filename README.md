# Surety Market Intelligence

A live dashboard for tracking surety-relevant industry news and top-account risk signals, built for surety industry underwriting use. Automated news discovery and analysis is handled by Claude; this repo currently hosts the front-end dashboard, with the goal of eventually managing the full pipeline (site + automation config) from here.

**Live site:** https://richiebuchanan.github.io/SuretyMarketIntelligence/

## What this is

A single-page dashboard that reads live from a Supabase database and shows:

- **Article ledger** — surety and construction-industry news, each scored 1–10 for underwriting relevance, with category (Contract Surety / Commercial Surety / Both / General), region, source, and a short AI-generated summary and underwriter insight per article. Filterable by category, region, source, company, date range, priority score, and free-text search.
- **6-Week Market Analysis** — a periodically-refreshed executive summary (key themes, critical risks, underwriting implications) synthesized from the recent article set.
- **Company tagging** — articles are tagged with the real company/companies they're about (not limited to any fixed list), so news on a specific account can be isolated via the Company filter.

All data — articles, the market analysis, and the tracked-company list — lives in Supabase and updates automatically. There is nothing to redeploy when new data comes in; only actual design or code changes to the page require a new commit here.

## Architecture

```
┌─────────────────────┐
│  Claude (scheduled   │  Runs ~daily. Searches for new industry news
│  task, once daily)   │  and news on watchlist companies, scores each
└──────────┬───────────┘  article, writes into Supabase.
           │
           ▼
┌─────────────────────┐
│      Supabase        │  Postgres database + REST API (PostgREST).
│  (acxdvzcohjayvmqdaoke)│  Public, read-only anon access — no auth
└──────────┬───────────┘  required for the dashboard to read data.
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

Three public, read-only tables (`anon`/`authenticated` roles have `SELECT` only via RLS policy; all writes happen through the scheduled task or direct SQL, not through the site):

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
| `relevance_category` | text | `Contract Surety` \| `Commercial Surety` \| `Both` \| `General` |
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
| `analysis` | jsonb | `{period_label, article_count, executive_summary, key_themes[], critical_risks[], underwriting_implications}` |

The dashboard always shows the single most recent row.

### `account_watchlist`
| column | type | notes |
|---|---|---|
| `company_name` | text | unique |

The list of companies the daily task specifically searches news for (in addition to general industry search). Not the same as `related_account` on `surety_articles` — articles can be tagged with any real company, watchlist or not; this table only drives which companies get a dedicated daily search pass.

## The daily automation

A Claude scheduled task (configured outside this repo, in Claude's Tasks settings — not yet version-controlled here) runs once a day and:
1. Processes any manually-flagged links from a Google Sheet queue
2. Searches trade press and general business press for new surety-relevant articles
3. Searches for news on each company in `account_watchlist`
4. Scores, classifies, and tags every new article, inserting into `surety_articles`
5. Writes a fresh `market_analysis` row periodically

## Updating the dashboard

There's no build step — `index.html` is the whole deployable artifact. To make a change:

1. Edit `index.html` (or hand the file to Claude to make the change and return an updated copy)
2. Commit the updated file to `main` — GitHub Pages auto-redeploys within a minute or two
3. No changes here are needed for new data — that flows in automatically via Supabase

## Roadmap

- [ ] Bring the scheduled-task configuration into this repo (currently lives only in Claude's Tasks UI)
- [ ] Consider GitHub Actions for deploy automation as the codebase grows beyond a single HTML file
- [ ] Expand `account_watchlist` toward the full top-100-accounts list
