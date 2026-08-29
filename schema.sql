-- ============================================================================
-- Surety Market Intelligence — Supabase schema
-- Project ref: acxdvzcohjayvmqdaoke
--
-- This file is a reference snapshot of the live schema (pulled from
-- information_schema + pg_policies on 2026-08-29). It is not yet wired into
-- a migrations tool — running it against a fresh Supabase project should
-- reproduce the current structure, but the live project is the source of
-- truth until this is adopted into `supabase/migrations`.
--
-- Five tables total. Only three are exposed to the public dashboard via
-- Row Level Security; the other two are back-office tables the daily
-- automation reads/writes via the Supabase service-role connection (used by
-- the `execute_sql` tool), and are invisible to the anon/public REST API.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. surety_articles  — PUBLIC READ
-- The main article ledger. Append-only: rows are never UPDATEd or DELETEd by
-- the automation. Deduplicated on `link` (UNIQUE) via ON CONFLICT DO NOTHING.
-- ----------------------------------------------------------------------------
create table public.surety_articles (
    id                        bigint generated always as identity primary key,
    date_found                date not null,                  -- when the automation found it (today, at insert time)
    article_title             text not null,
    link                      text not null unique,           -- dedup key
    source_site               text not null,                  -- e.g. "Construction Dive", "ENR (Engineering News-Record)"
    source_publish_date       date,                            -- the article's own publish date, if known
    region                    text not null,                   -- "Northeast (New York)" | "National" | "Global (Panama)" etc.
    relevance_category        text not null,                   -- 'Contract Surety' | 'Commercial Surety' | 'Both' | 'General'
                                                                 -- NOTE: not enforced by a CHECK constraint today — the
                                                                 -- automation's prompt is the only thing keeping this closed.
                                                                 -- Consider adding:
                                                                 --   check (relevance_category in ('Contract Surety','Commercial Surety','Both','General'))
    underwriter_value_score   smallint not null,                -- 1-10 (also not DB-enforced; prompt-level convention)
    score_rationale           text,                             -- one sentence
    summary                   text,                             -- 2-4 sentences
    bullet_points             text,                             -- "- " prefixed lines, separated by real newlines (plain text, not an array)
    underwriter_insights      text,                             -- 1-3 sentences
    flagged_by_user           boolean not null default false,   -- true if it came from surety_article_queue
    related_account           text[],                           -- real company name(s) the article is about; NULL = no specific company
    inserted_at               timestamptz not null default now()
);

alter table public.surety_articles enable row level security;

create policy "Public read-only access"
    on public.surety_articles
    for select
    to anon, authenticated
    using (true);

-- No insert/update/delete policy is defined for anon/authenticated, so the
-- dashboard (which only ever holds the anon key) cannot write to this table
-- under any circumstance — all writes happen out-of-band via the scheduled
-- task's Supabase MCP connection (service role), or by running SQL directly.


-- ----------------------------------------------------------------------------
-- 2. market_analysis  — PUBLIC READ
-- One row per day the analysis is refreshed. Append-only; the dashboard
-- always reads the single most recent row by (analysis_date, inserted_at).
-- ----------------------------------------------------------------------------
create table public.market_analysis (
    id             bigint generated always as identity primary key,
    analysis_date  date not null default current_date,
    analysis       jsonb not null,        -- see AUTOMATION.md for the exact shape
    inserted_at    timestamptz not null default now()
);

alter table public.market_analysis enable row level security;

create policy "Public read-only access"
    on public.market_analysis
    for select
    to anon, authenticated
    using (true);


-- ----------------------------------------------------------------------------
-- 3. account_watchlist  — PUBLIC READ
-- The list of companies the daily task runs one dedicated web search for,
-- on top of the general trade-press/business-press sweep. Currently 98 rows.
-- ----------------------------------------------------------------------------
create table public.account_watchlist (
    id            bigint generated always as identity primary key,
    company_name  text not null unique,
    added_at      timestamptz not null default now()
);

alter table public.account_watchlist enable row level security;

create policy "Public read-only access"
    on public.account_watchlist
    for select
    to anon, authenticated
    using (true);


-- ----------------------------------------------------------------------------
-- 4. surety_article_queue  — NOT PUBLIC (RLS enabled, zero policies)
-- Where Richie (or anyone with DB access) drops a link he wants force-added
-- to tomorrow's run, regardless of whether the automation would have found
-- it or thought it newsworthy on its own. NOT a Google Sheet — despite what
-- an earlier version of this README said, it has always been this table.
--
-- RLS is enabled with no policy at all, which means the anon/public API key
-- the dashboard uses gets zero rows here, always — there is currently no
-- front-end for adding to this queue. Rows go in via direct SQL today.
-- ----------------------------------------------------------------------------
create table public.surety_article_queue (
    id            bigint generated always as identity primary key,
    link          text not null,             -- no UNIQUE constraint — the same link can be queued twice
    notes         text,                       -- optional context for *why* it was flagged; passed to the automation verbatim
    added_at      timestamptz not null default now(),
    processed     boolean not null default false,
    processed_at  timestamptz
);

alter table public.surety_article_queue enable row level security;
-- Intentionally no policy — locked to service-role / direct SQL access only.


-- ----------------------------------------------------------------------------
-- 5. target_trade_publications  — NOT PUBLIC (RLS enabled, zero policies)
-- The standing list of trade-press sites/feeds the automation fetches
-- directly every run, in addition to ad hoc CNBC/Bloomberg web search.
-- Currently 13 rows (10 RSS feeds, 3 HTML listing pages scraped by prompt).
-- ----------------------------------------------------------------------------
create table public.target_trade_publications (
    id            bigint generated always as identity primary key,
    site_name     text not null,
    listing_url   text not null unique,
    source_type   text not null,             -- 'RSS' | 'HTML_LISTING'
    notes         text,                       -- operational notes the automation reads and follows, e.g. "don't use /rss/all.rss, it 404s"
    active        boolean not null default true,
    added_at      timestamptz not null default now()
);

alter table public.target_trade_publications enable row level security;
-- Intentionally no policy — locked to service-role / direct SQL access only.


-- ============================================================================
-- Adding a new trade-press site or watchlist company is just a plain INSERT,
-- e.g.:
--
--   insert into public.account_watchlist (company_name) values ('Acme Construction LLC');
--
--   insert into public.target_trade_publications (site_name, listing_url, source_type, notes)
--   values ('Some New Trade Rag', 'https://example.com/feed/', 'RSS', 'Confirmed fresh entries as of 2026-08-29.');
-- ============================================================================
