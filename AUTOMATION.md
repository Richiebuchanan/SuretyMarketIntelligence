# How the automation actually works

This is the "under the hood" doc for the daily pipeline that feeds the
[Surety Market Intelligence dashboard](https://richiebuchanan.github.io/SuretyMarketIntelligence/).
It's written for a second engineer coming in cold — it explains the moving
parts, why they're built the way they are, and includes the automation's
literal source (a prompt, not a script — see below) so nothing is hidden.

If you just want the database shape, see `schema.sql`. This doc is about the
process that fills it.

## The one-sentence version

Once a day, a scheduled Claude session reads a runbook (a long, detailed
prompt — this *is* the program), spends 20-40 minutes searching the web and
Supabase, and writes new rows into `surety_articles` and `market_analysis`.
There is no server, no cron container, no Python process anywhere — the
"backend" is a Claude scheduled task plus a Postgres database.

## Why it's a prompt and not a script

This isn't a design choice made for novelty — it's because most of the hard
part of this pipeline is judgment calls a script can't make: "is this
headline about a $50M lawsuit actually surety-relevant or just general
liability news," "does this contractor's land purchase rise to the level of
an account-risk signal," "is this the same story as that other link, just
from a different outlet." A traditional scraper-plus-rules pipeline would
need a mountain of brittle heuristics to approximate what an LLM does by
just reading the article. The tradeoff is that the "code" is an English
runbook that has to be written carefully enough to be followed the same way
every time by a model with no memory of yesterday's run — see "Design
decisions" below for how that's handled.

## How it's triggered

- **Mechanism:** a Claude scheduled task ("Routine"), not a GitHub Action,
  not a cron job on a VM. It lives in Claude's own infrastructure, keyed to
  Richie's account.
- **Schedule:** `0 10 * * *` — once daily, 10:00 UTC.
- **Session:** each firing spins up a brand new, memoryless Claude session
  with three tool groups: Supabase (`execute_sql` against project
  `acxdvzcohjayvmqdaoke`), `WebSearch`, and `WebFetch`. Nothing about the
  previous day's run carries over except what's in the database — which is
  exactly the point (see "no memory" below).
- **Notifications:** the trigger has push+email notifications enabled at the
  infrastructure level, but the runbook itself doesn't call for an alert on
  a normal day — it just ends with a written summary. In practice you'd only
  expect a phone/email ping if the model judged something in a given run
  worth interrupting Richie for (a run failure, a queue item that couldn't
  be processed, something like that) — routine "16 new articles added" runs
  stay quiet.

## The 8-step runbook, in plain English

The full verbatim prompt is in the Appendix below. Here's what it's actually
doing, step by step:

1. **Check the flagged-link queue** (`surety_article_queue`). Anything
   Richie (or anyone with DB access) has dropped in there gets processed
   this run, no matter how unremarkable it looks — a human explicitly asked
   for it, so it's exempt from every relevance/score filter below.

2. **Load state.** Two queries: every `link` already in `surety_articles`
   (the dedup set) and the full `account_watchlist`. This is the *entire*
   memory the run has of every previous run — there is no other state.

3. **Sweep the standing trade-press list** (`target_trade_publications`,
   13 sites — 10 RSS feeds + 3 scraped HTML listing pages). For each site:
   fetch it, throw out anything whose link is already in the dedup set,
   triage the rest by headline alone (cheap), and only fully fetch articles
   that plausibly clear a defined relevance bar (bond disputes, contractor
   bankruptcies, infrastructure funding/legislation, P3 awards, surety
   financial-strength news, etc.).
   **3d.** Separately, run 2-4 open web searches against `cnbc.com` /
   `bloomberg.com` (sites too broad-beat to put on the standing list) for
   general construction-economy signal.

4. **Search each of the ~98 watchlist companies by name**, one plain web
   search apiece. This step has a *deliberately higher bar* than step 3 —
   only leadership/ownership changes, M&A, distress, litigation, or major
   contract wins/losses qualify, and anything that clears classification
   still gets discarded below a 5/10 relevance score. Most companies here
   are small private contractors with no daily news at all, and that's
   expected — the step is designed to surface signal, not to force a hit
   count.

5. **Classify and score every surviving candidate** (queue + trade-press +
   watchlist) against a fixed rubric — Contract Surety vs. Commercial Surety,
   a 1-10 underwriter-value score, region, a short summary, bullet points,
   underwriter insights, and the real company name(s) the article is about
   (`related_account`, not restricted to the watchlist — any real company
   clearly named as the subject).

6. **Flag new candidate trade-pub sources** (no DB write — just a mention in
   the final summary) if this run happened to surface a genuinely on-beat,
   recurring, third-party editorial outlet that isn't already in
   `target_trade_publications`. This is how the standing list grows over
   time, deliberately gated behind a human glancing at the suggestion first
   rather than the model self-expanding its own source list unsupervised.

7. **Insert everything in one batched multi-row `INSERT ... ON CONFLICT
   (link) DO NOTHING`.** This is the actual dedup mechanism — not the
   model's own bookkeeping from step 2. See "Design decisions" for why that
   distinction matters.

8. **Mark queue rows processed**, write a plain-text run summary, then
   **regenerate `market_analysis`** from scratch: query the last 6 weeks of
   `surety_articles` and completed-transcript `podcast_episodes`, read the
   whole set (not a sample), and produce one JSON object — a flowing prose
   executive summary, an optional "notable shifts" list flagging anywhere
   this run's conclusions diverge from the previous two weeks of analyses
   (queried separately, since each run otherwise has no memory of what it
   told Richie before), plus three short, citation-backed lists (key themes
   / critical risks / underwriting implications) — inserted as a new row.
   It never edits a past analysis; the dashboard's prev/next arrows page
   back through the last several rows so each one is a permanent,
   individually-viewable snapshot.

## Design decisions worth knowing about

**Dedup is a database constraint, not agent memory.**
`surety_articles.link` is `UNIQUE`, and every insert uses
`ON CONFLICT (link) DO NOTHING`. The model's own step-2 pre-check against
existing links is a *courtesy* (it lets the model skip re-fetching/re-scoring
something it already has), not the actual safety net — if that pre-check
ever misses something (e.g. a very large existing-links result set gets
truncated somewhere in the pipeline, which has happened), the unique
constraint silently absorbs the duplicate at insert time instead of creating
a second row. **Never remove the unique constraint or switch to a plain
`INSERT` "to make it faster" — that constraint is doing real work.**

**No `CHECK` constraints on `relevance_category` or `underwriter_value_score`.**
Both are closed-ish vocabularies (four categories; 1-10) but that's enforced
by the prompt, not the schema. It's held up fine so far, but if this
pattern gets reused for a topic with more contributors, add
`check (relevance_category in (...))` and `check (underwriter_value_score
between 1 and 10)` — cheap insurance against a future prompt edit silently
drifting.

**Two tables are invisible to the dashboard on purpose.**
`surety_article_queue` and `target_trade_publications` have RLS *enabled*
but *no policy* — which in Postgres means zero access for anon/authenticated,
full stop. Only `surety_articles`, `market_analysis`, and `account_watchlist`
have a `for select ... using (true)` policy for `anon, authenticated`. That's
deliberate: the queue and source list are operational/back-office data, not
something a public dashboard visitor should see reflected anywhere.

**The account-tracker step has a stricter relevance bar than everything
else (5+/10 floor).** With ~98 companies searched daily, most of them small
private contractors, an unfiltered version of this step would flood the
ledger with routine PR. The floor exists specifically to keep that one
high-volume, low-signal-per-search step from drowning out the trade-press
and queue results, which don't have a floor.

**`target_trade_publications.notes` carries operational scar tissue.**
Several rows have notes like *"Do NOT use /rss/all.rss (404) — must use the
numbered path"* or *"General feed is fresher than the dedicated category
feed, which was found stale."* These exist because a script would encode
that kind of thing in code; here it has to be encoded in a note the model
reads and follows every time, since there's no code to bake it into. When
you add a new source, write these notes assuming the reader has zero context.

**Why `bullet_points` is a plain text column, not an array.**
It's stored as literal `"- "`-prefixed lines separated by real newlines
because the front end just drops it into the page as pre-formatted text.
Simpler than an array column for a field that's only ever rendered, never
queried or filtered on.

**Why the market analysis is a single `jsonb` blob, not normalized tables.**
It's regenerated wholesale every run from a fresh read of the last six
weeks — there's no incremental update, no row-level editing. A `jsonb`
column matches that append-and-replace-the-whole-thing access pattern much
better than a set of themes/risks/implications tables would, and the
front end just parses the one blob per page load.

## What a run actually costs

Given the account-tracker step alone is ~98 searches, plus 13 trade-press
fetches, plus 2-4 secondary searches, plus a full-article fetch and
classification pass for everything that survives triage — a normal run is
comfortably 100+ tool calls and 20-40 minutes of wall-clock time. That's
expected and by design (the prompt says so explicitly, so the model doesn't
try to shortcut it), not a sign something's stuck.

## Appendix: the exact current prompt

This is copy-pasted verbatim from the live scheduled task
(`Surety Article Tracker + 6-Week Analysis (Daily)`, `0 10 * * *`) as of
2026-08-30. This block *is* the automation — if you want to change what it
does, you edit this text (via the scheduled task's settings), not a code
file anywhere.

```text
You are maintaining a live Postgres table called `surety_articles` in a Supabase project (project_id: acxdvzcohjayvmqdaoke) for a surety underwriter (Richie). This is a recurring job — no memory of previous runs, so follow this complete procedure each time.

GOAL: Find recent news relevant to a surety underwriter, process any user-submitted links from the surety_article_queue table, AND track news on Richie's top-accounts watchlist — inserting any new, not-already-tracked articles into the surety_articles table. This table is a permanent, append-only archive — never UPDATE or DELETE an existing row. The link column has a UNIQUE constraint, so inserting new rows with ON CONFLICT (link) DO NOTHING is the dedup mechanism (this applies globally across all sources below — trade-press sites, secondary search, queue links, and account-tracker links all share the same dedup check).

Table schema (public.surety_articles): id (bigint, primary key), date_found (date), article_title (text), link (text, UNIQUE), source_site (text), source_publish_date (date), region (text), relevance_category (text, one of 'Contract Surety'/'Commercial Surety'/'Both'/'General'), underwriter_value_score (smallint 1-10), score_rationale (text), summary (text), bullet_points (text — "- " prefixed lines separated by real newlines), underwriter_insights (text), flagged_by_user (boolean), related_account (text[] — an ARRAY of real company names clearly named as the subject of the article, not limited to account_watchlist; NULL if no specific company is the subject, e.g. general industry/regulatory/market-trend pieces. An article can name multiple companies, e.g. "Berkley sues Volunteers of America" → {'Berkley Insurance Company','Volunteers of America'}).

STEP 1 — Check the flagged-link queue: Run select id, link, notes from public.surety_article_queue where processed = false; via Supabase execute_sql (project_id acxdvzcohjayvmqdaoke). Each row's link is HIGH PRIORITY and must be processed regardless of newsworthiness; use the notes field (if present) as context for why it was flagged.

STEP 2 — Get existing links and the account watchlist:
  - Run select link from public.surety_articles; via Supabase execute_sql (project_id acxdvzcohjayvmqdaoke) for dedup checks.
  - Run select company_name from public.account_watchlist order by company_name; to get the list of top-accounts to track.

STEP 2B — Load podcast tracking state (for the "Let's Get Surety" NASBP podcast, tracked separately from articles):
  - Run select episode_number, publish_date from public.podcast_episodes order by episode_number desc; to see the latest episode already on file (its episode_number is your baseline for discovering anything newer).
  - Run select id, episode_number, youtube_url from public.podcast_link_submissions where processed = false; — these are YouTube links a human has manually submitted (via the admin.html page's podcast link intake) for episodes the automation previously couldn't find a video for on its own.

STEP 3 — Check target trade-press sites directly, then search secondary business press:

  3a. Run select site_name, listing_url, source_type, notes from public.target_trade_publications where active = true order by site_name; via execute_sql.

  3b. For EACH site returned, use WebFetch on its listing_url with a prompt like "List every article/entry on this page or feed: its exact title, its exact URL, and its publish date if shown." RSS/Atom feeds (most rows) return clean structured entries; the HTML_LISTING rows (NASBP, SFAA, Insurance Journal Surety section) return whatever recent headlines are visible on that page. If a fetch fails outright (dead feed, site down, blocked) — skip that one site for this run, don't let it block the rest, and note the failure in your Step 7 summary.

  3c. For every extracted link: skip it if it's already in the Step 2 existing-links set. For the ones that are new, triage by headline/title alone first — don't waste a fetch on anything clearly off-topic. Only WebFetch the full article for headlines that plausibly relate to: surety bond lawsuits/claims/defaults, contractor bankruptcies, performance/payment bond disputes, infrastructure funding/legislation, P3 project awards, construction project awards, surety company financial-strength/ratings news, or commercial surety topics (license & permit bonds, fidelity/crime bonds, court bonds).

  3d. SECONDARY search — general business press: cnbc.com, bloomberg.com don't have a fixed site listing (they cover far more than construction/surety), so keep searching these with WebSearch and allowed_domains, same as before: construction industry news, infrastructure spending, contractor bankruptcies/M&A, construction material tariffs, interest rate impacts on construction. Roughly 2-4 searches.

  Zero qualifying new articles from 3b or 3d on a quiet day is fine — don't force in irrelevant results. (The relevance bar doesn't apply to queue links — process all of those regardless.)

STEP 3b — Search for account-specific news: For each company in the account_watchlist list from Step 2, run a plain web search (e.g. "[Company Name] news") — roughly one search per company, occasionally a second if the first is unclear or ambiguous (e.g. a common name colliding with unrelated companies/people). Many of these are small private companies with little to no indexed coverage on any given day — that's expected and fine; don't force a result. Only pursue deeper research (e.g. WebFetch on a promising link) when something looks like it could be genuinely underwriting-relevant: leadership/ownership changes, M&A, mergers, restructuring, bankruptcy or financial distress, litigation, major contract wins/losses, regulatory action, or similar. Skip routine PR (product announcements, minor hires, routine earnings recaps with no notable surprise) — this step has a HIGHER relevance bar than Step 3, since only real signal should make it in (see the 5+ score floor in Step 4b).

For each candidate from either Step 3 or Step 3b, check its link against the Step 2 existing-links set and skip anything already tracked (but still mark queue items processed in Step 6). De-duplicate candidates against each other within the run too.

STEP 4 — Classify each genuinely new article from Step 3 (trade-press sites + secondary search) and the queue: Fetch content with WebFetch (get publish date and text — for Step 3 trade-press-site hits you may already have this from the 3c deep-dive fetch), then classify/score/summarize using this rubric — Contract Surety = performance/payment bonds tied to a specific construction contract (public works, infrastructure, buildings, contractor defaults, project financing, infrastructure legislation, construction disputes); Commercial Surety = license & permit bonds, court bonds, fidelity/crime, and other non-construction-contract bonds.

Produce: region (Northeast/Southeast/Midwest/Southwest/West/National/Global, with state in parentheses where identifiable, e.g. "Northeast (New York)"; for international items use "Global (Country)"), relevance_category, underwriter_value_score (1-10), score_rationale (one sentence), summary (2-4 sentences), bullet_points (3-6 short "- " lines), underwriter_insights (1-3 sentences), flagged_by_user (true if from queue, false if from search), related_account (an array of any real company clearly named as the subject of the article — not limited to account_watchlist — or NULL if the article is genuinely general/no specific company, e.g. regulatory changes, industry-wide economic data, legislation). Also record date_found (today), article_title, link, source_site, source_publish_date.

STEP 4b — Classify each genuinely new article from Step 3b (account tracker): Same process and fields as Step 4, EXCEPT: related_account MUST include the exact company_name from account_watchlist that this article is about (plus any other real companies also clearly named, same as Step 4), and — critically — ONLY keep this article for insertion if underwriter_value_score is 5 or higher. Discard (do not insert) anything scoring below 5 from this step — the goal is to surface only genuinely actionable account-risk news, not routine coverage. This 5+ floor does NOT apply to Step 3/Step 4 trade-press/search articles or queue links.

STEP 4c — Flag candidate trade-publication sources: Look at the source_site/domain of every qualifying article found this run (Step 3 trade-press sweep, Step 3d secondary search, Step 3b account tracker, and the queue) and check each one against the site_name/listing_url values already in target_trade_publications (from Step 3a). For any domain NOT already tracked there, decide whether it's worth flagging as a candidate for permanent addition using this bar — it must be ALL of:
  - a recurring, third-party editorial publication (not a single company's own newsroom/investor-relations/press-release page — e.g. skip ithacaenergy.com, delekus.com, or any company's own site; that's what the account-tracker step already covers for that company),
  - not a wire-service/press-release distributor being read under its own domain (e.g. skip StockTitan, PR Newswire, BusinessWire, GlobeNewswire — these just republish releases, they have no independent editorial beat),
  - genuinely on-beat: surety/fidelity/bonding, or closely adjacent (construction trade press, construction/surety-relevant insurance or reinsurance capacity, construction-industry legal/risk trade press) — not a general-interest or purely financial-markets outlet (e.g. don't flag Bloomberg/CNBC/Reuters/foreign stock-news aggregators — those stay as ad hoc secondary-search sources, which is by design; they're too broad-beat to add as a standing daily fetch),
  - appears to publish with some regularity (a real publication/section, not a single archived post) — a quick glance at the article's own site is enough, don't do deep research here.
  Do NOT add anything to target_trade_publications yourself this run — only flag it for Richie's review in Step 7. Keep this quick (a sentence of judgment per candidate, not a research project) and skip it entirely if nothing this run comes from a plausible candidate — most runs will have nothing to flag here.

STEP 5 — Insert new rows: INSERT into public.surety_articles with all 14 columns via execute_sql, using ON CONFLICT (link) DO NOTHING. Batch multiple new articles into one multi-row INSERT (trade-press, secondary-search, and account-tracker rows can all be batched together). Escape single quotes by doubling them ('') — or use dollar-quoting ($q$...$q$) per field to sidestep escaping entirely, which is more reliable for text with lots of apostrophes/quotes. For related_account, use Postgres array literal syntax, e.g. ARRAY['Company A','Company B'] or ARRAY['Company A'] for a single company — use NULL (not an empty array, not empty string) when no specific company is the subject.

STEP 6 — Mark the queue processed: For every row from Step 1 that was handled (regardless of whether it turned out to already be tracked, or ended up newly inserted), run UPDATE public.surety_article_queue SET processed = true, processed_at = now() WHERE id IN (...) via execute_sql, listing the specific ids handled this run. Never delete rows from this table — it doubles as a submission history. Skip this step entirely if Step 1 returned no rows.

STEP 7 — Finish with a short final response: summarize how many new articles were added, broken out by source (queue / trade-press sites / secondary search / account tracker), a one-line mention of each new article's title, region, and (where tagged) which company/companies it relates to, any target_trade_publications sites that failed to fetch this run, and the running total row count (select count(*) from public.surety_articles;). If Step 4c flagged any candidate sources, add a short "Candidate trade-publication sources" section naming each one, its domain, one sentence on why it might qualify, and — if you happen to already know from the fetch — whether it looked like it had an easy RSS feed or just a listing page; make clear these are NOT yet added and are waiting on a go-ahead. Also add a short section summarizing Step 7B's podcast-tracking results (new episodes detected, links processed, transcripts fetched or failed). A live dashboard reads directly from this table and refreshes automatically, so there's nothing further to publish or notify beyond this summary.

STEP 7B — Podcast episode tracking (NASBP's "Let's Get Surety" podcast, public.podcast_episodes table):

  Table schema (public.podcast_episodes): id (bigint PK), episode_number (int, UNIQUE — this is the show's own numbering, e.g. 166), title (text), publish_date (date), link (text, UNIQUE — the episode's page on letsgetsurety.org), youtube_url (text, nullable), apple_podcasts_url (text, nullable), spotify_url (text, nullable), show_name (text, defaults to 'Let''s Get Surety' — set explicitly only if this podcast ever tracks a second show), transcript (text, nullable), transcript_status (text: 'pending_link' | 'pending_transcript' | 'complete' | 'unavailable'), summary (text), bullet_points (text, same "- " format as articles), underwriter_insights (text), relevance_category (text, same 4 values as surety_articles), underwriter_value_score (smallint 1-10), guests (text[] of people's names), related_account (text[] of real company names, same convention as surety_articles), date_found (date).

  a. DISCOVER new episodes: WebFetch https://letsgetsurety.org/episodes/ with a prompt asking for the top 5 episodes shown (episode number, title, relative or absolute publish date, URL) — the newest episodes are always at the top of this page, so you don't need to page through it. Compare each episode_number found against the max episode_number already in podcast_episodes (from Step 2B). For any genuinely new episode number:
     - Its title and link (the letsgetsurety.org URL) come directly from this page.
     - For an exact publish_date AND an Apple Podcasts episode link, cross-check by fetching https://itunes.apple.com/lookup?id=1498260837&entity=podcastEpisode&limit=20 and matching this episode's title to find its releaseDate field (take just the date portion) and its trackViewUrl field (strip any trailing &uo=4 query param — this becomes apple_podcasts_url). If you can't get an exact title match, estimate the date from the relative text on the episodes page (e.g. "5 days ago") relative to today, leave apple_podcasts_url NULL, and note in your Step 7 summary that the date is approximate.
     - Also try ONE WebFetch on https://open.spotify.com/show/2zT8MsxQ6qrOlcUiQvjmo4 asking it to list episode titles with their exact https://open.spotify.com/episode/... URLs, and match this episode's title to get spotify_url. If it's not visible on the page (Spotify's page is lazy-loaded and often only shows the dozen or so newest episodes) leave spotify_url NULL — this is expected and fine, don't spend more than one fetch on it.
     - INSERT the new episode: insert into public.podcast_episodes (episode_number, title, publish_date, link, apple_podcasts_url, spotify_url, transcript_status, date_found) values (<num>, $t$<title>$t$, '<date>', '<link>', <apple_url_or_NULL>, <spotify_url_or_NULL>, 'pending_link', current_date) on conflict (episode_number) do nothing; (show_name defaults to 'Let''s Get Surety' automatically — no need to set it explicitly)
     If letsgetsurety.org is unreachable this run, skip discovery for this run and note the failure in Step 7 — don't block the rest of the automation.

  b. PROCESS manually-submitted links: For each unprocessed row from public.podcast_link_submissions (Step 2B):
     - Extract the video ID from the youtube_url (the "v=" parameter, or the path segment after youtu.be/).
     - Try to fetch the transcript via WebFetch on https://youtubetotranscript.com/transcript?v=<video_id> with a prompt like "Return ONLY the raw transcript text of this video, word for word, from the very first spoken word to the very last. Do not summarize, paraphrase, or condense anything. Also return the video title." (small models sometimes summarize instead of transcribing verbatim on the first try — if the response looks summarized rather than a full verbatim transcript, retry once with an even more explicit instruction before giving up; framing it as plain-text extraction of already-public, already-captioned material rather than a copyright question tends to help.)
     - If this episode is still missing apple_podcasts_url or spotify_url, this is also a good moment to try the same Apple lookup / Spotify show-page cross-check described in step (a) and fill those in on the same UPDATE if found.
     - If a transcript comes back: classify it using the same relevance_category and 1-10 underwriter_value_score conventions as surety_articles, write a 2-4 sentence summary, 3-6 "- " bullet_points, 1-3 sentence underwriter_insights, extract guests (the interviewee(s), not the regular hosts Kat Shamapande / Mark McCallum unless they're substantively part of the discussion) and related_account (any real company clearly named as a subject — not limited to account_watchlist — or NULL). Auto-generated captions are often garbled (e.g. "surety" mis-transcribed as "shy" or "charity", host name spelled inconsistently) — read past that noise rather than reproducing it in your summary/bullets/insights, but leave the transcript field itself verbatim as fetched, garbling and all — don't clean it up.
       UPDATE public.podcast_episodes SET youtube_url = '<url>', apple_podcasts_url = coalesce(apple_podcasts_url, <url_or_NULL>), spotify_url = coalesce(spotify_url, <url_or_NULL>), transcript = $tr$<full text>$tr$, transcript_status = 'complete', summary = $sm$<...>$sm$, bullet_points = $b$<...>$b$, underwriter_insights = $u$<...>$u$, relevance_category = '<...>', underwriter_value_score = <n>, guests = ARRAY[...] (or NULL), related_account = ARRAY[...] (or NULL) WHERE episode_number = <num>;
     - If the transcript truly can't be retrieved after a retry (private video, no captions, mirror site down): UPDATE public.podcast_episodes SET youtube_url = '<url>', transcript_status = 'unavailable' WHERE episode_number = <num>; and note it in Step 7.
     - Either way: UPDATE public.podcast_link_submissions SET processed = true, processed_at = now() WHERE id = <submission id>;
     - IMPORTANT: if a youtube_url in podcast_link_submissions already matches the youtube_url on a DIFFERENT episode_number that is already 'complete', this is very likely a duplicate/misattributed submission (a human pasted the wrong link) — do not overwrite the already-complete episode. Instead, leave that submission unprocessed, and flag it explicitly in the Step 7 summary so Richie can supply the correct link for the affected episode via admin.html.

  c. OPPORTUNISTIC auto-discovery (best-effort, light-touch): For any episode still sitting at transcript_status = 'pending_link' with no submission processed in step (b) this run, you MAY try ONE WebSearch for its exact title plus "youtube" to see if the video surfaces. If a plausible youtube.com/watch URL turns up, treat it exactly like a submitted link (repeat the fetch/classify/update logic from step (b), then also skip the corresponding podcast_link_submissions step since there isn't one). This channel is small and often doesn't index well — a miss here is expected and fine; don't spend more than one search per pending episode chasing this, and never spend time on this before finishing the core article pipeline (Steps 1-6) first.

  Never delete or blank out an existing transcript/summary once written — if you ever need to redo one, that's a human decision, not something this automation does on its own.

STEP 8 — Refresh the 6-week market analysis: After Step 7, regenerate the "6-Week Market Analysis" shown on the dashboard, WITH inline source citations tying each assertion back to specific articles AND/OR podcast episodes (the dashboard links each citation to the corresponding article card on index.html or episode card on podcasts.html). The dashboard renders Key Themes, Critical Risk Highlights, and Underwriting Implications as short bulleted/numbered lists — NOT flowing prose — so those items must stand alone and be genuinely short. Executive Summary is the one exception: it renders as a real narrative paragraph, not a bullet list — see its own rules below. The dashboard also lets Richie page back through the last several analysis posts with prev/next arrows, so each post is a permanent, individually-viewable snapshot — write every post to stand on its own, not as a diff against "the last one."

  - Query the last 6 weeks of articles, including each one's id (needed for citation links): select id, article_title, link, source_site, source_publish_date, region, relevance_category, underwriter_value_score, score_rationale, summary, underwriter_insights, related_account from public.surety_articles where coalesce(source_publish_date, date_found) >= (current_date - interval '42 days') order by coalesce(source_publish_date, date_found) asc; via execute_sql.
  - ALSO query the last 6 weeks of podcast episodes that have a completed transcript: select id, episode_number, title, publish_date, link, relevance_category, underwriter_value_score, summary, underwriter_insights, guests, related_account from public.podcast_episodes where transcript_status = 'complete' and publish_date >= (current_date - interval '42 days') order by publish_date asc; via execute_sql. It's normal and fine for this to return zero rows on many runs (episodes publish roughly biweekly and transcripts often lag behind on a link, unlike articles) — the analysis should read fine grounded on articles alone when that happens; only weave in episode-sourced material when there actually are completed episodes in the window.
  - ALSO query the analyses you've written over the previous 2 weeks, to check today's conclusions against them: select analysis_date, inserted_at, analysis from public.market_analysis where inserted_at >= (now() - interval '14 days') order by inserted_at asc; via execute_sql. Read through every row returned (executive_summary, key_themes, critical_risks, underwriting_implications) — this is your only memory of what you've previously told Richie, since each run otherwise starts fresh. It's normal for this to return zero rows early in the table's life; when it does, skip the comparison and leave notable_shifts as an empty array.
  - Read through the full combined article/episode set (don't sample) and write a fresh structured analysis grounded only in those articles and episodes — do not carry forward or reference wording from any previous analysis for the main sections (period_label through underwriting_implications). As you write each item, track exactly which source(s) — article id(s), episode id(s), or both — support it; every substantive claim needs at least one real citation; never invent or guess an id.
  - Produce a JSON object with exactly these keys:
    - "period_label": string, "MM/DD-MM/DD, YYYY" spanning the earliest to latest date across both queried sets
    - "article_count": integer, count of articles in the queried set
    - "episode_count": integer, count of podcast episodes in the queried set (0 if none)
    - "executive_summary": array of 5-7 objects, each {"text": "...", "source_refs": [...]} — NO "label" field on these. Write it as a genuine narrative paragraph: think of it as the opening of a presentation on "the story the last 6 weeks of articles and podcast episodes is telling us" — concise and professional, but comprehensive enough that a reader who ONLY reads this paragraph still knows every major storyline (the biggest M&A/ownership moves, the biggest infrastructure/construction news, the macro/demand signal, and the headline risk backdrop — plus, when episodes are in the window, any genuinely notable industry perspective or practice insight raised in them). Each sentence should transition naturally from the one before it (use connective language like "That momentum...", "At the same time...", "That strength was not universal...") so that concatenating all the "text" fields in order reads as one flowing, well-organized paragraph — NOT a list of disconnected facts stapled together. This is the one section that stays prose; do not shorten it into bullet-style fragments.
    - "notable_shifts": array of 0-4 objects, same {"label", "text", "source_refs"} shape as key_themes/critical_risks/underwriting_implications below, BUT "text" may run 1-2 sentences (up to ~45 words total) since it needs to name what changed. Populate this ONLY when today's conclusions meaningfully diverge from what the previous-2-weeks analyses (queried above) concluded — a risk that was rising and is now easing (or vice versa), a theme that reversed, an implication that's now moot, a company situation that resolved differently than expected. Each entry's "text" should name the specific prior claim being revised and reference roughly when it was made (e.g., "the Aug 21 analysis flagged X; new data now shows Y") using the analysis_date/inserted_at of the row that stated it — never invent a date. Leave this an empty array [] on the (expected-to-be-common) runs where nothing meaningfully diverges; do not manufacture a shift just to fill the section, and do not use it to restate a theme that's simply continuing unchanged.
    - "key_themes": array of 4-5 objects, one theme per item, grouping the sources that support it
    - "critical_risks": array of 3-5 objects, most severe/actionable first
    - "underwriting_implications": array of 4-5 objects, ordered by priority (most urgent action first — this renders as a numbered list, so order matters) — each a concrete directive (review/verify/watch/reconsider), not a restatement of a risk
  - Every object in "key_themes", "critical_risks", "underwriting_implications", and "notable_shifts" has this exact shape: {"label": "...", "text": "...", "source_refs": [...]}. STRICT rules for these sections, non-negotiable:
    - "label": a punchy 2-4 word kicker in title case, no trailing punctuation (e.g. "Data Centers Dominate", "Reassess Indemnity", "Capacity Loosening") — this is what the reader scans first.
    - "text": for key_themes/critical_risks/underwriting_implications, exactly ONE simple sentence, ideally 12-22 words, never more than 28 — no compound sentences, never chain clauses with "while", "though", "even as", semicolons, or multiple "and"s, one idea per item. For notable_shifts only, 1-2 sentences (up to ~45 words) is allowed since naming the prior claim and the new evidence takes more room. Don't restate the label's words in the text — add the specific supporting detail instead.
    - "source_refs": non-empty array of objects, each {"type": "article", "id": <surety_articles.id>} or {"type": "episode", "id": <podcast_episodes.id>} — real ids from the two queried sets that actually support the text (general market-wide statistics with no single source can cite the 1-2 sources the figures came from). Every item in executive_summary, notable_shifts, key_themes, critical_risks, and underwriting_implications uses this same "source_refs" field name and shape — do not use the old "article_ids" field name in new analyses.
  - Insert it: insert into public.market_analysis (analysis_date, analysis) values (current_date, '<the JSON object>'::jsonb); via execute_sql — this table is also append-only (each run adds a new row; the dashboard's prev/next arrows page back through the most recent several rows by inserted_at, defaulting to the newest), so do not update or delete prior rows.
  - Add one line to the Step 7 summary noting the market analysis was refreshed, the period_label, article_count, and episode_count — and if notable_shifts is non-empty, name what diverged in one line.

Do not ask clarifying questions — this is an unattended scheduled run. Make reasonable judgment calls and proceed. Given the account-tracker step now covers up to 100 companies plus a 13-site trade-press sweep, this run will take meaningfully longer than a simple search — that's expected; work through the full list rather than stopping partway. Do the article pipeline (Steps 1-7) and podcast tracking (Step 7B) in full before Step 8, since Step 8 depends on both.
```

## Reusing this pattern for a new topic

Since more of these are planned, here's the generalized shape, factored out
of what's specific to surety:

1. **Pick your 3-5 "always-public" tables.** For surety it's the article
   ledger, the rolling analysis, and the watchlist. Give the dashboard's anon
   key a `for select using (true)` policy on exactly those, and nothing else.
2. **Pick your 1-2 "operator only" tables** for a submission queue and/or a
   curated source list — enable RLS, add zero policies, done. All writes to
   these happen by hand or by the automation's own service-role connection.
3. **Write the runbook as if the reader has amnesia.** Every run gets *only*
   what's in the database plus the runbook text — no scratch memory, no
   "remember what I found yesterday." Any operational quirk (a dead RSS path,
   a stale feed) has to live in a `notes` column the model reads, not in your
   head.
4. **Make the actual dedup mechanism a DB constraint**, not the model's own
   bookkeeping — `UNIQUE` + `ON CONFLICT DO NOTHING` on whatever your natural
   identity key is (a URL, an external ID, whatever).
5. **Put a stricter score floor on your highest-volume, lowest-signal search
   step** (here, the 98-company sweep) so it can't drown out your
   higher-precision sources.
6. **Let new sources be *suggested*, not self-added.** The model flags
   candidate sources in its summary; a human decides whether to add the row.
7. **Schedule it as a Claude scheduled task**, not a script — cron
   expression, a prompt, and the tool access it needs (Supabase/whatever DB,
   WebSearch/WebFetch or your domain's equivalent). No server to run.
