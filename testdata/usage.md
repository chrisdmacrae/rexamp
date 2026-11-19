# Usage

Signed in as chrisdmacrae@gmail.com
**Individual credits:** $9.99 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings

## How Usage Is Charged

- Models served by Amp: the token list price.
- Models served by your own provider connections: no Amp fee. The provider bills that inference directly.
- Amp-hosted orbs: the standard orb price (https://ampcode.com/docs/orbs/sizes-and-costs).
- Self-hosted orbs: free.
- Everything else, such as web search: its list price.

Range: 2026-11-12T04:21:24.118Z to 2026-11-19T04:21:24.118Z (end exclusive; trailing 7 days)
Total Orb runtime: 0.000s (0 ms)
Total tokens: 1,307,836
Total recorded cost: $0.005
Recorded cost outside the Models table: $0.005 (tools such as web search, orb runtime, and other features; thread drill-downs itemize them)

## How to Read Recorded Costs

Recorded cost is what Amp billed in dollars: to the Amp tier agent pool, granted credits, or paid credits. It never includes included orb hours, which are reported separately. Compare providers and models by recorded cost, never by tokens. On a linked model provider connection, recorded cost is only the Amp fee that How Usage Is Charged describes, never the provider’s inference charge, which the provider bills separately. Without an Amp fee, a linked connection records $0. A connection serves only the exact model IDs its mapping includes, and only while it is active; Amp serves and bills every other request, including requests while a connection is deactivated or paused, such as after choosing to use Amp until a provider usage limit resets.

A linked ChatGPT subscription covers only OpenAI models. Ultra mode, custom agents or dial modes on non-OpenAI models, image generation, and media viewing on non-OpenAI models bill Amp. With any connection, orb runtime and tool fees (web search, web extract) always bill Amp, and modes do not move supporting system models, such as media viewing, to your connections.

Amp paid tiers have two separate pools. Agent usage covers model inference and tool fees and is quoted in dollars; orb usage covers orb, Mac Satellite, and Box runtime and is quoted only in included orb hours, never in dollars. Exhausting agent usage does not affect orb usage, but once orb usage is exhausted, further runtime draws from agent usage and appears under its source (Orb, Mac Satellite, or Box) in the agent usage pool table. Included orb hours are counted in the tier's default orb size: a larger orb draws proportionally more included hours per hour of runtime and a smaller orb draws fewer, so included hours can exceed or fall short of wall-clock orb runtime. Mac Satellites and Boxes draw included orb hours at their own prices, not by size; a Box usually draws fewer included hours than its wall-clock runtime. Current period net usage and remaining balance include restored usage credits. Range tables show gross recorded usage before those credits.

Amp charges each request to the first source with a balance: included orb hours (orb, Mac Satellite, and Box runtime only), the Amp Free daily allowance when the account has one, the Amp tier’s agent usage, personal granted credits, then workspace free and paid credits for workspace members or personal paid credits otherwise.

Covered is usage not debited from paid credits, such as Amp tier or granted-credit usage. It excludes Amp Free and does not represent savings from a linked model provider subscription.

Paid is usage debited from paid credits. Those credits can belong to you, a workspace, or an enterprise, so Paid is not necessarily your personal out-of-pocket cost.

Costs for linked-provider inference billed outside Amp are not included. This report cannot estimate API-equivalent costs or subscription savings, including from ChatGPT.

A linked Claude subscription serves Claude models, including Claude Code threads, through Claude Code running on Amp’s servers. Amp records these requests like other linked connection requests, with their model and tokens, and their recorded cost is only the Amp fee, if any. When the subscription does not serve a Claude request, such as when a workspace disallows personal Model Routing, another connection or Amp serves and bills it. This report has no Claude subscription quota; check it at https://claude.ai/settings/usage.

## From

Sorted by recorded cost. Amp is usage billed to Amp; other sources are linked model provider connections.

| Source | Tokens | Recorded cost |
| --- | ---: | ---: |
| Amp | 0 | $0.005 |
| Claude Subscription | 1,307,836 | $0.00 |

## Models

Sorted by recorded cost. Uncached input, cache read, cache write, and output tokens add up to Tokens.

| Model | Uncached input | Cache read | Cache write | Output | Tokens | Recorded cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Opus 5.5 | 48 | 1,143,807 | 155,183 | 8,798 | 1,307,836 | $0.00 |

## Daily Recorded Cost

| Date (UTC) | Covered | Paid | Total |
| --- | ---: | ---: | ---: |
| 2026-11-19 | $0.01 | $0.00 | $0.01 |

## Top Threads by Tokens

Token counts cover only the selected range. These rows are sorted by tokens; a token-heavy thread on a linked provider can cost little or nothing. Use Usage by Thread for cost.

| Thread | Tokens | Covered | Paid | Total |
| --- | ---: | ---: | ---: | ---: |
| Amp Rex usage HUD (T-01a1f207-0418-7029-a6f2-9d659bcca151) | 1,243,415 | $0.01 | $0.00 | $0.01 |
| Amp beginner's guide (T-01a1f141-876e-7554-b054-6b1b27654b74) | 64,421 | $0.00 | $0.00 | $0.00 |

## Usage by Thread

These rows are sorted by recorded cost plus included orb hours. Token counts cover only the selected range.

| Thread | Tokens | Covered | Paid | Total |
| --- | ---: | ---: | ---: | ---: |
| Amp Rex usage HUD (T-01a1f207-0418-7029-a6f2-9d659bcca151) | 1,243,415 | $0.01 | $0.00 | $0.01 |
  <!-- Run `amp threads usage T-01a1f207-0418-7029-a6f2-9d659bcca151 --details --start 2026-11-12T04:21:24.118Z --end 2026-11-19T04:21:24.118Z` for range-scoped detailed thread usage. Query multiple relevant thread rows with the same range and sum their Orb runtime milliseconds when a selected-thread subtotal is needed. -->
| Amp beginner's guide (T-01a1f141-876e-7554-b054-6b1b27654b74) | 64,421 | $0.00 | $0.00 | $0.00 |
  <!-- Run `amp threads usage T-01a1f141-876e-7554-b054-6b1b27654b74 --details --start 2026-11-12T04:21:24.118Z --end 2026-11-19T04:21:24.118Z` for range-scoped detailed thread usage. Query multiple relevant thread rows with the same range and sum their Orb runtime milliseconds when a selected-thread subtotal is needed. -->

Thread rows use the thread ID recorded on each event. Subagent usage can appear in its own row.

<!-- Account and thread usage lookups share a limit of 60 requests per hour. Each lookup uses one request. Start with no more than the three most relevant thread drill-downs. -->
<!-- Run `amp usage --start <timestamp> --end <timestamp>` for credit usage details for a date range. -->
