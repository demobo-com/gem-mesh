# Corvid-1 internal evaluation report

Version 0.9, October 20, 2026. CONFIDENTIAL. Corvid Labs employees only. Do not share outside the company, and never
paste into a third-party AI service.

## Summary

Corvid-1 is within 2 to 4 points of the leading frontier models from Anthropic (Claude) and OpenAI (GPT) on knowledge
and reasoning benchmarks, leads both on long-context retrieval, and costs about one sixth as much per token. It trails
on agentic coding. The gap there is our main research priority for Corvid-2.

## Models compared

| Model | Provider | How we ran it |
|---|---|---|
| Corvid-1 | Corvid Labs | Our production endpoint, October 15 build |
| Claude (latest frontier) | Anthropic | Public API, default settings, extended thinking off unless noted |
| GPT (latest frontier) | OpenAI | Public API, default settings, reasoning effort "medium" unless noted |

Every model was run on the same prompts, with the same tools, on October 16 to 18, 2026. Scores are the mean of three
runs. Differences under 1 point are within run-to-run noise.

## Headline results

| Benchmark | What it measures | Corvid-1 | Claude | GPT |
|---|---|---|---|---|
| MMLU-Pro | Broad knowledge, hard multiple choice | 84.1 | 86.0 | 85.7 |
| GPQA Diamond | Graduate-level science reasoning | 74.8 | 78.2 | 77.5 |
| AIME 2026 | Competition math | 81.3 | 83.0 | 85.1 |
| LiveCodeBench (Oct) | Fresh coding problems | 68.5 | 72.9 | 71.4 |
| SWE-bench Verified | Fixing real GitHub issues, agentic | 58.2 | 71.6 | 68.9 |
| RULER 128K | Long-context retrieval at 128K tokens | 94.7 | 89.3 | 90.1 |
| Long-doc QA (internal) | Questions over 300-page contracts and filings | 88.9 | 84.2 | 83.6 |
| tau-bench (retail) | Multi-step tool use with a simulated customer | 71.0 | 74.5 | 73.8 |

## Cost and speed

| Measure | Corvid-1 | Claude | GPT |
|---|---|---|---|
| Price per million output tokens (list) | $2.50 | $15.00 | $14.00 |
| Blended price per million tokens (3:1 input to output) | $1.10 | $6.75 | $6.25 |
| Time to first token, median | 180 ms | 520 ms | 470 ms |
| Output speed, median | 142 tokens/s | 68 tokens/s | 75 tokens/s |
| Context window | 256K | 200K | 256K |

At the blended price, Corvid-1 is about 6x cheaper than Claude and 5.7x cheaper than GPT. It starts answering about
3x faster and streams about 2x faster.

## Where we win

1. **Long documents.** On RULER 128K, Corvid-1 scores 94.7, five points ahead of the best frontier model. On our
   internal long-document benchmark (300-page contracts, 10-K filings, clinical trial protocols) we lead by 4.7
   points. This is the core of our enterprise pitch: law firms, banks and insurers.
2. **Cost at quality.** Within 2 points on MMLU-Pro at one sixth of the price. For high-volume customers, this is the
   difference between a pilot and a production deployment. Our three largest API customers switched from a frontier
   lab for this reason.
3. **Latency.** 180 ms to first token makes Corvid-1 usable for voice agents and live autocomplete, where frontier
   models feel slow.

## Where we trail

1. **Agentic coding.** On SWE-bench Verified we are 13.4 points behind Claude. Most failures are in multi-file edits
   and in running the test suite correctly. Corvid-2 adds 4x more agentic training data and a longer tool-use
   curriculum. Target: within 5 points by the end of Q2 2027.
2. **Competition math.** 3.8 points behind GPT on AIME 2026. GPT's lead grows to 7 points when its reasoning effort is
   set to "high", at about 4x the cost.
3. **Tool use.** 3.5 points behind on tau-bench, mostly from policy mistakes in refund flows. A fine-tuning fix is in
   testing.

## Long-document results by domain

| Domain (internal long-doc QA) | Documents | Corvid-1 | Claude | GPT |
|---|---|---|---|---|
| Commercial contracts | 32 | 91.4 | 86.0 | 85.2 |
| 10-K and 10-Q filings | 28 | 89.7 | 85.9 | 84.8 |
| Clinical trial protocols | 20 | 86.1 | 82.3 | 82.0 |
| Insurance policies | 16 | 86.8 | 81.5 | 81.1 |

The lead holds in every domain. It is widest on contracts, where answers depend on cross-references between distant
clauses, and narrowest on clinical protocols, where all three models miss the same dosing tables.

## Customer evaluations

- **A top-10 US law firm** ran a 6-week bake-off on 400 of its own merger agreements. Corvid-1 was preferred by its
  associates in 61% of blind comparisons with Claude and 64% with GPT. Contract signed in September: $1.2M a year.
- **A regional bank** tested loan-file review. Accuracy matched the frontier models; cost was 81% lower. Pilot
  extended to production.
- **An insurer** found Corvid-1 slower to adopt its claims-handling style guide. A fine-tune fixed it in two weeks.

## Changes since version 0.8

- Added RULER 128K and the insurance-policy domain.
- Re-ran SWE-bench Verified with the fixed harness: Corvid-1 went from 55.9 to 58.2, the frontier models were
  unchanged.
- Removed HumanEval: every model now scores above 95, so it no longer separates them.

## Safety and reliability

- Refusal rate on our benign-but-sensitive set (medical, legal, security questions that should be answered): 2.1%,
  versus 3.4% for Claude and 2.8% for GPT.
- Harmful-request compliance on our red-team set: 0.4%, in line with both frontier models.
- Hallucination rate on long-document QA (claims not supported by the document): 3.2%, versus 5.1% and 5.6%.
- API uptime, last 90 days: 99.93%.

## Caveats (read before quoting any number)

- **Do not quote the AIME 2026 score externally yet.** The contamination check on our pre-training data is still
  running; results are due November 4.
- Frontier models change without notice. These numbers are from October 16 to 18 and may already be out of date.
- Long-doc QA is our own benchmark, built from our customers' document types. Say "internal benchmark" whenever we cite
  it.
- Claude and GPT were run with default settings. With maximum thinking or reasoning effort they score higher on math
  and coding, at a much higher cost. Be ready for that question.

## Recommended talking points for investors

- Lead with **cost and long context**, not overall rank.
- Frame the coding gap as **known and funded**: the Corvid-2 plan, its cost ($22M) and its target.
- Cite the hallucination rate on long documents. Enterprise buyers care about it more than benchmarks.

## Methodology notes

- MMLU-Pro, GPQA Diamond and AIME 2026 are zero-shot with chain of thought; answers are extracted automatically and
  checked by hand on a 5% sample.
- SWE-bench Verified uses our open-source agent harness, the same for every model, with a 30-minute limit per task.
- RULER uses the standard 13-task suite at 128K tokens.
- Long-doc QA has 1,200 questions over 96 documents, graded by two lawyers and one physician against the source text.
- Latency was measured from us-west-2 at 2 p.m. Pacific on weekdays, 500 requests per model.

*Demo data: Corvid Labs, its model and every number in this report are fictional.*
