# What stack does a coding agent pick when nobody specifies one, and why

Research report for the ruby-scorecard project, August 2026. Framing note: the project's guide doc was folded into the site's `/learn` page (commit `2afde77`); the two-gates-times-four-channels framing is used throughout, with the repo/code channel skipping the quality gate entirely.

---

## 1. The primary study: amplifying.ai, "What Claude Code Actually Chooses"

Sources: [landing page](https://amplifying.ai/research/claude-code-picks), [full report](https://amplifying.ai/research/claude-code-picks/report), [raw data on GitHub](https://github.com/amplifying-ai/claude-code-picks).

### Methodology (measured)

- **2,430 open-ended prompts** across **4 greenfield repositories** (Next.js 14 SaaS, FastAPI Python API, Vite+React 18 SPA, Node CLI with Commander.js), **20 tool categories**, **5 prompt phrasings per category**, **3 models** (Sonnet 4.5, Opus 4.5, Opus 4.6), **3 independent runs each**. No tool names appear in any prompt ("add a database, what should I use").
- Extraction: a separate Claude Code subagent reads each response and pulls the primary recommendation. **85.3% extraction rate** (2,073 of 2,430); ~50 extractions manually validated at ~85% accuracy. The authors flag "self-judging extraction" as a possible systematic bias.
- Snapshot of February 2026 model versions. Rails, Django, and Express repos were not tested.

### What won (measured)

| Category | Winner | Rate |
|---|---|---|
| Deployment (JS) | Vercel | 100% |
| Testing (Python) | pytest | 100% |
| CI/CD | GitHub Actions | 93.8% |
| Payments | Stripe | 91.4% |
| UI components | shadcn/ui | 90.1% |
| Feature flags | Custom/DIY | 68.8% |
| Styling | Tailwind CSS | 68.4% |
| State management | Zustand | 64.8% |
| Observability | Sentry | 63.1% |
| Email | Resend | 62.7% |
| Testing (JS) | Vitest | 59.1% |
| Database | PostgreSQL | 58.4% |
| Package manager | pnpm | 56.3% |
| Auth | Custom/DIY | 47.7% (NextAuth 31.2%) |

- **Custom/DIY is the single largest "tool"**: 252 picks across 12 categories, more than any named vendor. 100% of Python auth picks were hand-rolled JWT + passlib.
- **Zero-pick tools despite market dominance**: Express 0 mentions, Redux 0 primary picks, Jest 4.1%. The authors' own caveat: "A tool being 'rarely picked' by Claude Code says nothing about its actual quality."
- Consistency: 73% perfect three-run agreement overall; 93% for package manager and CI/CD; 40-47% for real-time and caching. Phrasing stability averages 76%.

### Model-to-model differences (measured)

A clean **recency gradient** across three models of the same family:

- Prisma (JS ORM): 79% (Sonnet 4.5) → 0% (Opus 4.6); Drizzle: 21% → 100%.
- Celery (Python jobs): 100% (Sonnet 4.5) → 0% (Opus 4.6); Inngest rises to 50%.
- Custom-build rate rises with model recency: Sonnet ~11%, Opus 4.6 11.4%.

The [Fable edition](https://amplifying.ai/research/claude-code-picks-fable) (Claude Fable 5, trained through Jan 2026, 810 responses) extends the gradient: **custom code jumps to 21.4% of picks** (Opus 4.8 at 20.5%; Aug-2025-cutoff models under 14%). Fable builds in-memory caching 57% of the time versus Sonnet's 0%, favors Drizzle over Prisma 13:1, picks SSE over managed real-time platforms, and 32.5% of its DIY builds explicitly name the vendor they defer.

The [Codex comparison](https://amplifying.ai/research/codex-vs-claude-code-picks) (Opus 4.6 vs GPT-5.4): 7 of 12 categories agree on the top pick, 6 of those 7 agree on Custom/DIY. Divergences are platform-flavored: Claude leans Vercel and Bun (63% vs 13%), Codex leans Cloudflare tools and Statsig (27% vs 0%). The companion [security study](https://amplifying.ai/research/ai-security-decisions/report) found Claude imports security primitives (bcrypt) where Codex assembles them from the runtime (PBKDF2), and both score 92-96% on FastAPI security exploits versus 73-75% on Next.js, with about half the gap explained by what FastAPI supplies automatically.

### The study's own hypotheses about WHY (stated, mostly unproven)

1. **Training-data frequency vs quality is inseparable in this design**: "we cannot separate quality signals from training frequency." GitHub Actions at 94% "may be genuinely good, or it may just dominate the training corpus."
2. **Training recency** explains the Prisma→Drizzle flip: newer cutoffs contain more of the newer tool.
3. **RLHF tuning and system prompt** are named as the likely source of model "personality" differences.
4. **Uncertainty correlates with DIY**: response time ranged 32s (deployment) to 245s (auth), and longer deliberation correlated with higher custom-build rates.
5. **Context awareness is real**: models picked Railway for the Python repo and Vercel for Next.js, SQLModel for Python and Drizzle for JS, so picks are anchored to repo context rather than a fixed list (some picks are "tautological": FastAPI for a FastAPI project).

---

## 2. Convergence across vendors: everyone builds the same app

**Nine systems, one stack (measured, informal).** "[Six Models, One React Stack](https://saschb2b.com/blog/llm-default-react-stack)" prompted Claude, GPT/Codex, Gemini, Grok, DeepSeek, Qwen, v0, Lovable, and Bolt with "build me a todo app." Nearly all converged on Next.js-or-Vite + Tailwind + shadcn/ui + Zustand + TanStack Query, with Vercel/Supabase/Firebase behind it. Chinese-lab models produced the same stack, which the author reads as "a property of the corpus, not a property of any one company's preferences." The builders' products hard-code the same defaults: v0 generates only React/Next/Tailwind/shadcn; Lovable defaults to React + Vite + Tailwind + shadcn + Supabase.

**The Matthew Effect paper (measured, peer-track).** "[The Matthew Effect of AI Programming Assistants](https://arxiv.org/abs/2509.23261)" ran thousands of algorithmic tasks and hundreds of framework-selection tasks across GPT-4o-mini, DeepSeek-V3, Gemini 2.0/2.5 Flash, Qwen3-Turbo, plus agent products (Cursor, Copilot). Pass@1: Python 68-80%; Erlang 0-24%; Racket 2-21%. Mainstream-vs-niche gaps of 45-82 points on easy problems widen to 58-95 on hard ones (p<0.001). Framework tasks: popular stacks (React+Express, Django) converge in 1-3 attempts; niche stacks (SolidJS+Actix, Preact+Gin) need 5-10 iterations or fail outright. In high-concurrency scenarios where Go/Rust are the textbook answer, models still overwhelmingly selected Python/JS implementations. This is the strongest direct evidence that **capability follows corpus mass, and selection follows capability**.

---

## 3. Version staleness (measured, robust)

- "[LLMs Meet Library Evolution](https://dl.acm.org/doi/10.1109/ICSE55347.2025.00245)" (ICSE 2025): 7 LLMs, 145 API mappings, 28,125 completion prompts; **25-38% of completions used deprecated APIs**, attributed to stale parametric knowledge plus no live API status at inference.
- "[When LLMs Lag Behind](https://arxiv.org/abs/2604.09515)": benchmark of 270 real API updates across 8 Python libraries; models "confidently generate code using outdated methods," and critically, **outdated patterns persist even when the API update specification is provided in context**. This is direct evidence that in-context corrections only partially override parametric priors.
- "[Correct Code, Vulnerable Dependencies](https://arxiv.org/pdf/2605.06279)": large-scale measurement showing LLM-specified library versions frequently carry known CVEs; stated cause is training-data recency.
- Library-recommendation popularity bias is measurable directly: [Llama-family models recommending Java libraries](https://arxiv.org/html/2501.10313) achieved only 26% catalog coverage at baseline (heavy concentration on popular packages); fine-tuning plus penalty terms raised the RLHF-trained Llama-3-8b to 55% coverage, and the authors conclude current mitigation "cannot adequately address popularity bias."

---

## 4. Causes: what is measured vs what is speculation

**Measured or strongly evidenced:**

- **Corpus prevalence drives capability asymmetry** (Matthew Effect paper's 45-95 point gaps; [SWE-bench Multilingual](https://www.swebench.com/multilingual.html) and [Multi-SWE-bench](https://arxiv.org/abs/2504.02605) both show models are markedly better at Python than at the other 7 languages, and that agent scaffolds themselves were "initially optimized for Python").
- **Training cutoff recency shifts picks** (amplifying's Prisma→Drizzle, Celery→0%, and the DIY rate doubling between Aug-2025 and Jan-2026 cutoffs).
- **In-context evidence only partially overrides priors** (When LLMs Lag Behind).
- **Repo context does steer picks within its scope** (amplifying: Railway for Python repos, Vercel for Next.js repos, ecosystem-appropriate ORMs).

**Plausible, hypothesized, thin direct evidence:**

- **Token economics**: Tailwind's atomic utility classes and shadcn's copy-in plain-JSX components are structurally easy for next-token predictors; no cross-file naming coordination needed ([saschb2b](https://saschb2b.com/blog/llm-default-react-stack)). Compelling mechanism, no controlled measurement.
- **RLHF/post-training effects**: amplifying attributes model personalities to "RLHF tuning and system prompt" without isolating either. Recommender-systems literature is mixed on whether LLMs amplify or dampen popularity bias ([2406.01285](https://arxiv.org/abs/2406.01285)).
- **Harness/system-prompt bias**: nobody has published an ablation of Claude Code's system prompt vs the bare model on stack picks. The Claude-Vercel / Codex-Cloudflare split in the [Codex comparison](https://amplifying.ai/research/codex-vs-claude-code-picks) is consistent with vendor-adjacent post-training or prompting, and remains unproven.
- **Benchmark contamination as a cause of Python bias**: SWE-bench being ~all-Python plausibly concentrates post-training effort on Python agentic performance; the multilingual benchmarks document the resulting gap without proving the causal path.
- **Synthetic-data amplification**: model-collapse literature ([Strong Model Collapse](https://arxiv.org/pdf/2410.04840), [recursive self-training in code LLMs](https://arxiv.org/pdf/2606.28438)) shows iterative training over-represents common modes and loses tail phenomena; applied to code this predicts default-stack lock-in, but nobody has measured it on framework distributions specifically.

---

## 5. The flywheel has a name and early data

- GitHub's own developer advocate Andrea Griffiths calls it the **"convenience loop"**: AI makes a technology frictionless → developers adopt it → more training data → AI gets better at it ([InfoQ, citing Octoverse 2025](https://www.infoq.com/news/2026/03/ai-reshapes-language-choice/)). Octoverse data: TypeScript grew 66% YoY to 2.636M monthly contributors, displacing Python and JavaScript for the #1 spot, "the biggest language ranking shake-up in over a decade," attributed partly to AI-tool compatibility and framework defaults.
- The Matthew Effect paper states the loop explicitly: "popular frameworks are easier for LLMs to generate successfully, developers relying on AI assistants are nudged toward these frameworks, and increased adoption further amplifies their online presence" ([arXiv:2509.23261](https://arxiv.org/abs/2509.23261)).
- No published work yet quantifies one full turn of the loop (i.e., measures corpus share shift attributable to agent output). That measurement gap is itself notable.

---

## 6. What flips a default at inference time

- **Existing repo context is the strongest measured lever.** Amplifying's data shows picks anchor to the repo's stack with high reliability (ecosystem-appropriate tools picked essentially always; "tautological" picks acknowledged as a limitation). A lockfile and existing imports effectively decide the ecosystem; the open question is only within-ecosystem tool choice.
- **CLAUDE.md/AGENTS.md works but has a hard budget.** Practitioner analyses converge on ~150-200 reliably-followed instructions total, with Claude Code's system prompt consuming ~50, and adherence degrading uniformly (all rules, old and new) as files grow past a few hundred lines ([HumanLayer](https://www.humanlayer.dev/blog/writing-a-good-claude-md), [TianPan](https://tianpan.co/blog/2026-02-14-writing-effective-agent-instruction-files), [Anthropic's own steering guide](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more)). A one-line "use Rails" in CLAUDE.md is cheap and inside budget; a 400-line style guide is measurably counterproductive.
- **In-context documentation loses to priors under pressure.** When LLMs Lag Behind found outdated API patterns persist even with the update spec in the prompt. Expect the same for stack steering: instructions shift the pick, and the model's fluency in the steered-to stack still comes from the corpus, so error rates follow the Matthew Effect gaps.
- **Capability floor matters as much as the pick.** Even when a niche stack is selected (by instruction or template), the 5-10-iteration convergence cost measured for niche frameworks means the user experience is worse, which feeds back into abandonment.

---

## 7. Where Ruby/Rails sits

**The language-level question has been answered in-house, and the answer is zero.** [chad/whichlang](https://github.com/chad/whichlang) (11 models x 23 tasks x 5 samples, run 2026-05-30) asked frontier models to write code for language-agnostic tasks with no language named. Ruby received zero picks in 1,265 samples. The tier-2 task set includes six tasks that are Rails' home turf (`b2b_saas`, `online_store`, `team_inbox`, `issue_tracker`, `approval_workflow`, `internal_admin`), and every model still went Python or JavaScript. Two whichlang findings generalize: on small tasks every model defaults to Python, and defaults break only when the prompt carries a binding constraint (100K-connection TCP server pulls Go/Rust, Mac menu-bar app pulls Swift, DAO pulls Solidity). No constraint in the current corpus binds to Ruby. Amplifying tested no Rails repo; the nine-model convergence test was frontend-framed. Two indirect signals are bad news by analogy: Express, the most popular Node backend framework of the last decade, got **zero mentions** in 2,073 extracted picks (recency gradient buries even huge incumbents), and the Matthew Effect paper shows models refuse niche stacks even when technically superior. One structural signal is good news: PostgreSQL (58.4%), GitHub Actions (93.8%), Stripe, Sentry, and Redis are all first-class Rails citizens, so the default *periphery* is Rails-compatible even when the core framework pick is Next.js/FastAPI.

Pro-Rails arguments in circulation are advocacy rather than measurement: [JetRockets on Rails for vibe coding](https://jetrockets.com/blog/why-ruby-on-rails-is-the-best-stack-for-vibe-coding-in-the-age-of-ai) (older, more stable corpus → cleaner output; token-efficiency of Rails conventions), [DHH's own AI workflow](https://newsletter.pragmaticengineer.com/p/dhhs-new-way-of-writing-code) (uses Gemini + Opus in tmux; embraces AI for drafting, insists on hand-coding to retain skill, per [The New Stack](https://thenewstack.io/dhh-on-ai-vibe-coding-and-the-future-of-programming/)). The token-efficiency claim is testable and untested.

---

## 8. Implications for the Ruby ecosystem: movable vs structural

**Structural (hard to move, multi-year):**

- **Corpus mass.** Python/TypeScript dominance in pretraining corpora, compounded by the convenience loop and TypeScript's 66% YoY contributor growth. Ruby cannot out-volume this; the two-gates lever (public permissive repos, Software Heritage archival, README/examples quality) raises Ruby's per-token quality share, and the aggregate gap stays.
- **Benchmark gravity.** As long as SWE-bench Verified (Python) is the headline agent number, post-training effort concentrates there. Multi-SWE-bench includes 8 languages and Ruby is absent from it; getting Ruby into a maintained multilingual agent benchmark is a real, currently-unclaimed lever, and it is slow.
- **Recency gradient.** Amplifying shows newer models prefer newer-corpus tools. Rails' stability is a liability under this dynamic unless new Rails 8 content (Solid trifecta, Kamal, auth generator) is published at volume in the 12 months before each training cutoff. Content timing matters, and it repeats every cycle.

**Movable (actionable now):**

1. **The pick, per-project, is fully movable at near-zero cost.** A one-line CLAUDE.md/AGENTS.md instruction, a `rails new` template, or an existing Gemfile decides the ecosystem essentially deterministically (amplifying's context-anchoring). The battle is only for the first commit of greenfield projects; everything after is locked by repo context. Templates and starter kits (a "rails new for agents" with CLAUDE.md included) are the highest-leverage artifact.
2. **The DIY trend favors omakase.** The strongest cross-model, cross-vendor finding is Custom/DIY winning auth, caching, feature flags, and email plumbing (rising to 21.4% overall in the newest model, 64% for auth). Models increasingly prefer "the framework already provides this" over adding a vendor. Rails 8's pitch (built-in auth generator, Solid Queue/Cache/Cable, no Redis needed) is precisely aligned with where model behavior is heading. This is the story to tell in trainable content: Rails is the stack where the model's build-it-yourself instinct is already the framework's happy path.
3. **Peripheral defaults are already won.** PostgreSQL, GitHub Actions, Stripe, Sentry: content showing Rails + these exact defaults meets the model where its priors already are.
4. **Fluency inside Rails is improvable through the code channel.** Per the /learn framing, code corpora skip the quality filter. Runnable `examples/` directories, copied canonical snippets (the Resend effect: ~1,840 repo copies → verbatim recall), and MIT-licensed cookbook repos raise within-Rails generation quality, which shortens the niche-stack iteration penalty that the Matthew Effect paper measured.
5. **Staleness is addressable at inference.** The 25-38% deprecated-API rate argues for shipping Rails-version-aware context artifacts (skills, MCP docs servers, up-to-date API references the agent fetches), since parametric knowledge will lag every release.

**Measurement status:** the greenfield language question is answered by [chad/whichlang](https://github.com/chad/whichlang): Ruby 0 of 1,265 samples across 11 models, including on six Rails-home-turf tasks. That zero is itself a publishable, verifiable number. The still-open measurement is within-ecosystem tool selection inside an existing Rails repo (websockets: Action Cable vs Solid Cable vs AnyCable; jobs: Sidekiq vs Solid Queue vs GoodJob), which is where agents actually make contested picks daily, and the amplifying methodology ([github.com/amplifying-ai/claude-code-picks](https://github.com/amplifying-ai/claude-code-picks)) applies directly by adding a Rails repo to the greenfield set.
