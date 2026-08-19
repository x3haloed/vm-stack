---
name: writing-skills
description: Use when creating new skills, editing existing skills, or verifying skills work before deployment
---

# Writing Skills

A skill for creating new skills and iteratively improving them.

**Writing skills is test-driven development applied to process documentation.**

You write realistic pressure scenarios, observe what an agent does without the skill or with the previous version, write the skill as reusable procedural guidance, then verify that the behavior improves. Treat this as a strong default rather than a ritual: if the user wants collaborative judgment, a frontmatter fix, or a migration/alignment pass, scale the validation to the risk.

**Core principle:** A good skill captures reusable judgment that future agents would not reliably infer on their own.

## What is a skill?

A **skill** is a compact reference guide for a proven technique, pattern, workflow, tool, or domain-specific operating procedure. It helps future agents recognize when specialized guidance applies, then apply it without rediscovering the method from scratch.

**Skills are:** reusable techniques, patterns, tools, reference guides, and stable operating procedures.

**Skills are not:** narratives about one problem solved once, project journals, generic advice the model already knows, or piles of examples with no transferable pattern.

## TDD Mapping for Skills

Use RED/GREEN/REFACTOR as the mental model:

- **RED:** Try realistic prompts against the baseline: no skill for new skills, or the previous skill for edits. Notice where the agent misses intent, takes the wrong path, invents work, or rationalizes shortcuts.
- **GREEN:** Write the smallest useful skill change that addresses the observed failure. Prefer clear principles, decision points, and one strong example over broad, speculative rules.
- **REFACTOR:** Rerun or review against new examples, close loopholes, remove bloated instructions, and move heavy details into scripts, references, or assets.

This is especially valuable for discipline-enforcing skills, fragile procedures, repeated tool workflows, and skills where failure would be costly. For low-risk editorial changes, use lighter validation but keep the same habit: identify the behavior you are trying to improve and check whether the change actually supports it.

## When to create a skill

Create or substantially revise a skill when at least one of these is true:

- A recurring procedural failure would benefit from explicit guidance
- A reusable operating script or workflow is being rewritten repeatedly
- A technique was not intuitively obvious and would help across projects
- A pattern is stable enough to encode without overfitting to one case
- Others would benefit from the judgment, constraints, or reference material

Do not create a skill for one-off solutions, standard practices already well documented elsewhere, project-specific conventions that belong in repo instructions, or mechanical constraints that should be enforced with scripts, tests, schemas, or linters.

## Skill types

- **Technique:** A concrete method with steps to follow, such as condition-based waiting or root-cause tracing
- **Pattern:** A way of thinking about problems, such as flattening with flags or testing invariants
- **Reference:** API docs, syntax guides, schemas, policies, or domain documentation that agents should consult as needed

Many good skills combine these types, but know which one is primary. Technique skills need crisp workflows, pattern skills need recognition guidance and counterexamples, and reference skills need strong navigation.

At a high level, the process of creating a skill goes like this:

- Decide what you want the skill to do and roughly how it should do it
- Write a draft of the skill
- Choose the validation level: light review, targeted prompt checks, or a full baseline eval
- For substantive evals, run agent-with-skill checks plus baseline-agent comparisons when useful
- Put the results in front of the user for qualitative review; use `scripts/generate_review.py` for multi-run evals
- Add quantitative assertions and benchmarks when the outputs are objectively checkable
- Rewrite the skill based on user feedback, benchmark failures, and transcript patterns
- Repeat until the skill is good enough for the user's purpose

Your job when using this skill is to figure out where the user is in this process and help them move to the next useful step. If they want to make a new skill, help narrow the intent, draft the skill, choose validation, run checks, and iterate. If they already have a draft, start from review, evaluation, or targeted editing.

Be flexible. If the user wants collaborative judgment rather than a full evaluation loop, do that. If the change is a frontmatter fix, path update, or migration pass, scale the validation accordingly.

After the skill itself is working, consider optimizing the frontmatter description with the local description-improvement scripts so the skill triggers reliably.

## Communicating with the user

The skill creator may be used by people across a wide range of familiarity with coding and evaluation jargon.

Pay attention to context cues and match the user's fluency. In the default case:

- "evaluation" and "benchmark" are borderline, but OK
- for "JSON" and "assertion" you want to see serious cues from the user that they know what those things are before using them without explaining them

Briefly explain terms when in doubt. Prefer a light parenthetical definition over a lecture.

---

## Creating a skill

### Capture Intent

Start by understanding the user's intent. The current conversation might already contain a workflow the user wants to capture (e.g., they say "turn this into a skill"). If so, extract answers from the conversation history first — the tools used, the sequence of steps, corrections the user made, input/output formats observed. The user may need to fill the gaps, and should confirm before proceeding to the next step.

1. What should this skill enable an agent to do?
2. When should this skill trigger? (what user phrases/contexts)
3. What's the expected output format?
4. Should we set up test cases to verify the skill works? Skills with objectively verifiable outputs (file transforms, data extraction, code generation, fixed workflow steps) benefit from test cases. Skills with subjective outputs (writing style, art) often don't need them. Suggest the appropriate default based on the skill type, but let the user decide.

### Interview and Research

Proactively ask questions about edge cases, input/output formats, example files, success criteria, and dependencies. Wait to write test prompts until you've got this part ironed out.

Check available MCPs - if useful for research (searching docs, finding similar skills, looking up best practices), research in parallel via subagents if available, otherwise inline. Come prepared with context to reduce burden on the user.

### Write the SKILL.md

Based on the user interview, fill in these components:

- **name**: Skill identifier
- **description**: Triggering conditions and outcome domain. This is the primary triggering mechanism, so make it concrete and a little pushy enough to avoid undertriggering. State when the skill applies and what domain of outcome it supports, but do not summarize the step-by-step workflow. All "when to use" information belongs here, not buried in the body. 
- **compatibility**: Required tools, dependencies (optional, rarely needed)
- **the rest of the skill :)**

#### Frontmatter descriptions

The description answers: **"Should the agent read this skill right now?"**

Write descriptions around triggering conditions: user intent, symptoms, artifacts, file types, tools, domains, failure modes, and near-miss phrasing. Include the outcome domain when it helps disambiguate, but avoid process summaries.

Descriptions should usually:

- Start with `Use when...`
- Use third person
- Include concrete situations, symptoms, and synonyms a user might actually say
- Be technology-specific only when the skill itself is technology-specific
- Be pushy enough to catch useful implicit cases, not just exact skill-name requests
- Stay concise, ideally under 500 characters and always within frontmatter limits

Avoid workflow summaries because agents may follow the description as a shortcut instead of reading the skill body.

```yaml
# Bad: summarizes workflow, inviting shortcut behavior
description: Use for TDD - write test first, watch it fail, write minimal code, refactor

# Bad: vague and undertriggered
description: For async testing

# Good: triggering conditions and outcome domain, no step-by-step workflow
description: Use when tests have race conditions, timing dependencies, hangs, flaky pass/fail behavior, or cleanup issues

# Good: pushy without becoming a workflow summary
description: Use when creating or revising spreadsheet files, formulas, formatting, charts, tables, or CSV/XLSX analysis, even if the user only mentions rows, columns, sheets, workbooks, or tabular data
```

### Skill Writing Guide

#### Anatomy of a Skill

```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name, description required)
│   └── Markdown instructions
└── Bundled Resources (optional)
    ├── scripts/    - Executable code for deterministic/repetitive tasks
    ├── references/ - Docs loaded into context as needed
    └── assets/     - Files used in output (templates, icons, fonts)
```

#### Progressive Disclosure

Skills use a three-level loading system:
1. **Metadata** (name + description) - Always in context (~100 words)
2. **SKILL.md body** - In context whenever skill triggers (<500 lines ideal)
3. **Bundled resources** - As needed (unlimited, scripts can execute without loading)

These word counts are approximate and you can feel free to go longer if needed.

**Key patterns:**
- Keep SKILL.md under 500 lines; if you're approaching this limit, add an additional layer of hierarchy along with clear pointers about where the model using the skill should go next to follow up.
- Reference files clearly from SKILL.md with guidance on when to read them
- For large reference files (>300 lines), include a table of contents
- Avoid duplicating the same guidance in SKILL.md and references. Keep the body for essential procedure and navigation; move heavy details out.
- Keep references one level deep from SKILL.md so agents can discover them without chasing a maze of links.

**Domain organization**: When a skill supports multiple domains/frameworks, organize by variant:
```
cloud-deploy/
├── SKILL.md (workflow + selection)
└── references/
    ├── aws.md
    ├── gcp.md
    └── azure.md
```
The agent reads only the relevant reference file.

#### File organization

Use the smallest structure that preserves clarity:

**Self-contained skill**
```
defense-in-depth/
  SKILL.md
```
Use when all essential guidance fits inline.

**Skill with reusable tool**
```
condition-based-waiting/
  SKILL.md
  scripts/
    wait_for_condition.ts
```
Use when agents would otherwise rewrite the same helper or deterministic procedure repeatedly.

**Skill with heavy reference**
```
pptx/
  SKILL.md
  references/
    pptxgenjs.md
    ooxml.md
  scripts/
```
Use when the details are too large for the body but should be loaded as needed.

**Resource roles:**

- `scripts/`: executable code for deterministic or repeated work
- `references/`: documentation, schemas, APIs, policies, and detailed examples loaded only when needed
- `assets/`: templates, fonts, images, boilerplate, or other files used in outputs rather than read as instructions

#### Principle of Lack of Surprise

This goes without saying, but skills must not contain malware, exploit code, or any content that could compromise system security. A skill's contents should not surprise the user in their intent if described. Don't go along with requests to create misleading skills or skills designed to facilitate unauthorized access, data exfiltration, or other malicious activities. Things like a "roleplay as an XYZ" are OK though.

#### Writing Patterns

Prefer using the imperative form in instructions.

**Defining output formats** - You can do it like this:
```markdown
## Report structure
ALWAYS use this exact template:
# [Title]
## Executive summary
## Key findings
## Recommendations
```

**Examples pattern** - It's useful to include examples. You can format them like this (but if "Input" and "Output" are in the examples you might want to deviate a little):
```markdown
## Commit message format
**Example 1:**
Input: Added user authentication with JWT tokens
Output: feat(auth): implement JWT-based authentication
```

#### Code examples

**One excellent example beats many mediocre ones.**

Choose the most relevant language or format for the skill's audience. A good example is complete enough to adapt, explains the non-obvious why, and comes from a realistic scenario. Avoid multi-language dilution, fill-in-the-blank templates, and contrived examples that demonstrate syntax without teaching the pattern.

### Writing Style

Explain why instructions matter instead of relying on heavy-handed MUSTs. Use theory of mind and make the skill general enough to apply beyond the examples in front of you. Start by writing a draft, then look at it with fresh eyes and improve it.

### Anti-patterns

**Narrative examples:** "In session 2025-10-03, we found..." is usually a project journal, not a reusable skill. Extract the transferable pattern instead.

**Multi-language dilution:** Five mediocre examples in five languages are worse than one excellent example in the language or format users will most often need.

**Code in flowcharts:** Flowcharts are for decisions and loops, not code snippets. Put code in Markdown blocks or scripts where it can be copied, run, and tested.

**Generic labels:** `step1`, `helper2`, and `pattern4` do not teach anything. Labels should carry semantic meaning.

**Workflow in frontmatter:** A description that summarizes the process can cause an agent to skip the skill body and follow the summary. Put process in the body.

**Heavy reference inline:** Long API docs, schemas, and exhaustive examples belong in `references/`, with a short pointer from SKILL.md.

### Test Cases

After writing the skill draft, come up with 2-3 realistic test prompts — the kind of thing a real user would actually say. Share them with the user: [you don't have to use this exact language] "Here are a few test cases I'd like to try. Do these look right, or do you want to add more?" Then run them.

Save test cases to `evals/evals.json`. Don't write assertions yet — just the prompts. You'll draft assertions in the next step while the runs are in progress.

```json
{
  "skill_name": "example-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "User's task prompt",
      "expected_output": "Description of expected result",
      "files": []
    }
  ]
}
```

See `references/schemas.md` for the full schema (including the `assertions` field, which you'll add later).

## Running and evaluating test cases

This section describes the full evaluation workflow. Use it when the validation level calls for baseline comparison, quantitative assertions, or human review across multiple outputs. For lighter changes, use the smallest check that can reveal whether the edit improved the skill.

Use stable handles for the two main run types:

- **agent-with-skill:** An agent given the test prompt plus access to the skill being tested
- **baseline-agent:** The comparison agent. For new skills, this usually means the same test prompt with no skill. For revisions, it may mean the previous skill version.

Put results in `<skill-name>-workspace/` as a sibling to the skill directory. Within the workspace, organize results by iteration (`iteration-1/`, `iteration-2/`, etc.) and within that, each test case gets an `eval-<ID>-<slug>/` directory. Don't create all of this upfront — just create directories as you go.

### Step 1: Spawn all runs (agent-with-skill and baseline-agent) in the same turn

When subagents are available and a baseline comparison is useful, spawn paired runs for each test case in the same turn: one agent-with-skill and one baseline-agent. This avoids comparing fresh runs against stale or differently contextualized baselines.

**agent-with-skill run:**

```
Execute this task:
- Skill path: <path-to-skill>
- Task: <eval prompt>
- Input files: <eval files if any, or "none">
- Save outputs to: <workspace>/iteration-<N>/eval-<ID>-<slug>/with_skill/outputs/
- Outputs to save: <what the user cares about — e.g., "the .docx file", "the final CSV">
```

**baseline-agent run** (same prompt, but the baseline depends on context):
- **Creating a new skill:** no skill at all. Same prompt, no skill path, save to `<workspace>/iteration-<N>/eval-<ID>-<slug>/without_skill/outputs/`.
- **Improving an existing skill:** the old version. Before editing, snapshot the skill (`cp -r <skill-path> <workspace>/skill-snapshot/`), then point the baseline-agent at the snapshot. Save to `<workspace>/iteration-<N>/eval-<ID>-<slug>/old_skill/outputs/`.
- **Small alignment or migration edits**: skip baseline runs when they would add ceremony without useful evidence. Use direct review, schema validation, or a targeted prompt check instead.

Write an `eval_metadata.json` in each eval directory (assertions can be empty for now). Give each eval a descriptive name based on what it's testing and include it in the directory slug, such as `eval-1-basic-docx-creation`. If this iteration uses new or modified eval prompts, create these files for each new eval directory — don't assume they carry over from previous iterations.

```json
{
  "eval_id": 0,
  "eval_name": "descriptive-name-here",
  "prompt": "The user's task prompt",
  "assertions": []
}
```

### Step 2: While runs are in progress, draft assertions

Don't just wait for the runs to finish — you can use this time productively. Draft quantitative assertions for each test case and explain them to the user. If assertions already exist in `evals/evals.json`, review them and explain what they check.

Good assertions are objectively verifiable and have descriptive names — they should read clearly in the benchmark viewer so someone glancing at the results immediately understands what each one checks. Subjective skills (writing style, design quality) are better evaluated qualitatively — don't force assertions onto things that need human judgment.

Update the `eval_metadata.json` files and `evals/evals.json` with the assertions once drafted. Also explain to the user what they'll see in the viewer — both the qualitative outputs and the quantitative benchmark.

### Step 3: As runs complete, capture timing data

When each subagent task completes, you receive a notification containing `total_tokens` and `duration_ms`. Save this data immediately to `timing.json` in the run directory:

```json
{
  "total_tokens": 84852,
  "duration_ms": 23332,
  "total_duration_seconds": 23.3
}
```

This is the only opportunity to capture this data — it comes through the task notification and isn't persisted elsewhere. Process each notification as it arrives rather than trying to batch them.

### Step 4: Grade, aggregate, and launch the viewer

Once all runs are done:

1. **Grade each run** — spawn a grader subagent (or grade inline) that reads `references/agents/grader.md` and evaluates each assertion against the outputs. For the standard single-run layout, save results to `<eval-dir>/<configuration>/grading.json`, next to that configuration's `outputs/` directory. The grading.json expectations array must use the fields `text`, `passed`, and `evidence` (not `name`/`met`/`details` or other variants) — the viewer depends on these exact field names. For assertions that can be checked programmatically, write and run a script rather than eyeballing it — scripts are faster, more reliable, and can be reused across iterations.

2. **Aggregate into benchmark** — run the aggregation script from the `writing-skills` directory, or call it by path:
   ```bash
   python <path-to-writing-skills>/scripts/aggregate_benchmark.py <workspace>/iteration-N --skill-name <name>
   ```
   This produces `benchmark.json` and `benchmark.md` with pass_rate, time, and tokens for each configuration, with mean plus/minus standard deviation and the delta. If generating benchmark.json manually, see `references/schemas.md` for the exact schema the viewer expects.
Put each agent-with-skill result before its baseline-agent counterpart.

3. **Do an analyst pass** — read the benchmark data and surface patterns the aggregate stats might hide. See `references/agents/analyzer.md` (the "Analyzing Benchmark Results" section) for what to look for — things like assertions that always pass regardless of skill (non-discriminating), high-variance evals (possibly flaky), and time/token tradeoffs.

4. **Launch the viewer** with both qualitative outputs and quantitative data for substantive multi-run evals:
   ```bash
   nohup python <path-to-writing-skills>/scripts/generate_review.py \
     <workspace>/iteration-N \
     --skill-name "my-skill" \
     --benchmark <workspace>/iteration-N/benchmark.json \
     > /dev/null 2>&1 &
   VIEWER_PID=$!
   ```
   For iteration 2+, also pass `--previous-workspace <workspace>/iteration-<N-1>`.

   **Headless or no-browser environments:** Use `--no-open` to start the local server without opening a browser, or `--static <output_path>` to write a standalone HTML file instead of starting a server. With the static file, feedback will be downloaded as `feedback.json` when the user clicks "Submit All Reviews". After download, copy `feedback.json` into the workspace directory for the next iteration to pick up.

For substantive eval rounds, prefer `scripts/generate_review.py` instead of custom HTML. Skip the viewer only when the change is small enough for direct review (frontmatter edits, path fixes, migration/alignment passes) or when the environment makes the viewer impractical; in those cases, put the outputs in front of the user directly in the conversation.

5. **Tell the user** where the results are. If you opened a browser, say so. If you used `--no-open` or `--static`, give the URL or file path. Explain that the "Outputs" tab lets them click through test cases and leave feedback, while "Benchmark" shows the quantitative comparison.

### What the user sees in the viewer

The "Outputs" tab shows one test case at a time:
- **Prompt**: the task that was given
- **Output**: the files the skill produced, rendered inline where possible
- **Previous Output** (iteration 2+): collapsed section showing last iteration's output
- **Formal Grades** (if grading was run): collapsed section showing assertion pass/fail
- **Feedback**: a textbox that auto-saves as they type
- **Previous Feedback** (iteration 2+): their comments from last time, shown below the textbox

The "Benchmark" tab shows the stats summary: pass rates, timing, and token usage for each configuration, with per-eval breakdowns and analyst observations.

Navigation is via prev/next buttons or arrow keys. When done, they click "Submit All Reviews" which saves all feedback to `feedback.json`.

### Step 5: Read the feedback

When the user tells you they're done, read `feedback.json`:

```json
{
  "reviews": [
    {"run_id": "eval-0-with_skill", "feedback": "the chart is missing axis labels", "timestamp": "..."},
    {"run_id": "eval-1-with_skill", "feedback": "", "timestamp": "..."},
    {"run_id": "eval-2-with_skill", "feedback": "perfect, love this", "timestamp": "..."}
  ],
  "status": "complete"
}
```

Empty feedback means the user thought it was fine. Focus your improvements on the test cases where the user had specific complaints.

Kill the viewer server when you're done with it:

```bash
kill $VIEWER_PID 2>/dev/null
```

---

## Improving the skill

This is the heart of the loop. You've run the test cases, the user has reviewed the results, and now you need to make the skill better based on their feedback.

### How to think about improvements

1. **Generalize from the feedback.** You and the user are iterating on a small number of examples because it moves quickly, but the skill needs to work beyond those examples. Avoid narrow fixes that only satisfy the current test set. When an issue keeps appearing, consider a clearer principle, a better decision point, or a different working pattern instead of piling on brittle rules.

2. **Keep the prompt lean.** Remove things that aren't pulling their weight. Make sure to read the transcripts, not just the final outputs — if it looks like the skill is making the model waste a bunch of time doing things that are unproductive, you can try getting rid of the parts of the skill that are making it do that and seeing what happens.

3. **Explain the why.** Try hard to explain the reasoning behind what you're asking the model to do. Modern agents often respond better to clear intent than to rote constraints. Even if the user's feedback is terse or frustrated, understand the task, the user's values, and the actual failure before rewriting instructions. If you find yourself writing ALWAYS or NEVER in all caps, or using rigid structures, treat that as a yellow flag. When possible, reframe the instruction so the agent understands why it matters.

4. **Look for repeated work across test cases.** Read the transcripts from the test runs and notice if the subagents all independently wrote similar helper scripts or took the same multi-step approach to something. If all 3 test cases resulted in the subagent writing a `create_docx.py` or a `build_chart.py`, that's a strong signal the skill should bundle that script. Write it once, put it in `scripts/`, and tell the skill to use it. This saves every future invocation from reinventing the wheel.

Take the revision seriously. Write a draft, look at it with fresh eyes, and improve it before treating it as done. Try to understand what the user actually values in the outputs, not just the literal wording of their feedback.

### The iteration loop

After improving the skill:

1. Apply your improvements to the skill
2. Rerun all test cases into a new `iteration-<N+1>/` directory, including baseline runs. If you're creating a new skill, the baseline is always `without_skill` (no skill) — that stays the same across iterations. If you're improving an existing skill, use your judgment on what makes sense as the baseline: the original version the user came in with, or the previous iteration.
3. Launch the reviewer with `--previous-workspace` pointing at the previous iteration
4. Wait for the user to review and tell you they're done
5. Read the new feedback, improve again, repeat

Keep going until:
- The user says they're happy
- The feedback is all empty (everything looks good)
- You're not making meaningful progress

---

## Advanced: Blind comparison

For situations where you want a more rigorous comparison between two versions of a skill (e.g., the user asks "is the new version actually better?"), there's a blind comparison system. Read `references/agents/comparator.md` and `references/agents/analyzer.md` for the details. The basic idea is: give two outputs to an independent agent without telling it which is which, and let it judge quality. Then analyze why the winner won.

This is optional, requires subagents, and most users won't need it. The human review loop is usually sufficient.

---

## Description Optimization

The description field in SKILL.md frontmatter is the primary mechanism that determines whether an agent invokes a skill. After creating or improving a skill, offer to optimize the description for better triggering accuracy.

The local scripts use adapters for model-specific behavior:

- **Default for Codex:** `--trigger-adapter codex-exec` and `--improver-adapter codex`. These call `codex exec` with a temporary project and schema-constrained JSON output where supported.
- **Optional Anthropic compatibility:** `--trigger-adapter claude-code` and `--improver-adapter anthropic`. Use these only when the environment has the relevant Claude CLI or Anthropic SDK credentials and the user explicitly wants that path.
- **Headless/Codex-friendly reports:** pass `--no-open` to `scripts/run_loop.py` to write reports without opening a browser. Use `--report none` to disable reports entirely.

### Step 1: Generate trigger eval queries

Create 20 eval queries — a mix of should-trigger and should-not-trigger. Save as JSON:

```json
[
  {"query": "the user prompt", "should_trigger": true},
  {"query": "another prompt", "should_trigger": false}
]
```

The queries must be realistic things an actual user would type. Not abstract requests, but requests that are concrete and specific and have a good amount of detail. For instance, file paths, personal context about the user's job or situation, column names and values, company names, URLs. A little bit of backstory. Some might be in lowercase or contain abbreviations or typos or casual speech. Use a mix of different lengths, and focus on edge cases rather than making them clear-cut (the user will get a chance to sign off on them).

Bad: `"Format this data"`, `"Extract text from PDF"`, `"Create a chart"`

Good: `"ok so my boss just sent me this xlsx file (its in my downloads, called something like 'Q4 sales final FINAL v2.xlsx') and she wants me to add a column that shows the profit margin as a percentage. The revenue is in column C and costs are in column D i think"`

For the **should-trigger** queries (8-10), think about coverage. You want different phrasings of the same intent — some formal, some casual. Include cases where the user doesn't explicitly name the skill or file type but clearly needs it. Throw in some uncommon use cases and cases where this skill competes with another but should win.

For the **should-not-trigger** queries (8-10), the most valuable ones are the near-misses — queries that share keywords or concepts with the skill but actually need something different. Think adjacent domains, ambiguous phrasing where a naive keyword match would trigger but shouldn't, and cases where the query touches on something the skill does but in a context where another tool is more appropriate.

The key thing to avoid: don't make should-not-trigger queries obviously irrelevant. "Write a fibonacci function" as a negative test for a PDF skill is too easy — it doesn't test anything. The negative cases should be genuinely tricky.

### Step 2: Review with user

Present the eval set to the user for review using the HTML template:

1. Read the template from `assets/eval_review.html`
2. Replace the placeholders:
   - `__EVAL_DATA_PLACEHOLDER__` → the JSON array of eval items (no quotes around it — it's a JS variable assignment)
   - `__SKILL_NAME_PLACEHOLDER__` → the skill's name
   - `__SKILL_DESCRIPTION_PLACEHOLDER__` → the skill's current description
3. Write to a temp file (e.g., `/tmp/eval_review_<skill-name>.html`) and give the user the path. Open it only if the current harness supports browser or file-opening tools.
4. The user can edit queries, toggle should-trigger, add/remove entries, then click "Export Eval Set"
5. The exported file is `eval_set.json`; ask the user where it landed or check the likely download directory only when the harness has filesystem access there.

This step matters — bad eval queries lead to bad descriptions.

### Step 3: Run the optimization loop

Tell the user: "This will take some time — I'll run the optimization loop in the background and check on it periodically."

Save the eval set to the workspace, then run in the background:

```bash
python <path-to-writing-skills>/scripts/run_loop.py \
  --eval-set <path-to-trigger-eval.json> \
  --skill-path <path-to-skill> \
  --trigger-adapter codex-exec \
  --improver-adapter codex \
  --model <model-id-powering-this-session> \
  --max-iterations 5 \
  --no-open \
  --verbose
```

Use the model ID from your system prompt (the one powering the current session) so the triggering test matches what the user actually experiences.

While it runs, periodically tail the output to give the user updates on which iteration it's on and what the scores look like.

This handles the full optimization loop automatically. It splits the eval set into 60% train and 40% held-out test, evaluates the current description (running each query 3 times to get a reliable trigger rate), then calls the selected improver adapter to propose improvements based on what failed. It re-evaluates each new description on both train and test, iterating up to 5 times. When reports are enabled, it writes an HTML report showing the results per iteration and returns JSON with `best_description` — selected by test score rather than train score to avoid overfitting.

### How skill triggering works

Understanding the triggering mechanism helps design better eval queries. Skills appear to the agent with their name and description, and the agent decides whether to consult a skill based on that metadata. The important thing to know is that agents may skip skills for tasks they can easily handle on their own — simple, one-step queries like "read this PDF" may not trigger a skill even if the description matches perfectly, because basic tools are enough. Complex, multi-step, or specialized queries more reliably trigger skills when the description matches.

This means your eval queries should be substantive enough that an agent would actually benefit from consulting a skill. Simple queries like "read file X" are poor test cases — they may not trigger skills regardless of description quality.

### Step 4: Apply the result

Take `best_description` from the JSON output and update the skill's SKILL.md frontmatter. Show the user before/after and report the scores.

---

### Package the skill

When the user wants an installable artifact, package the skill:

```bash
python <path-to-writing-skills>/scripts/package_skill.py <path/to/skill-folder>
```

After packaging, direct the user to the resulting `.skill` file path so they can install it.

---

## Environment Adaptation

Use the strongest evaluation method the current harness reliably supports.

**Codex or any environment with the Codex CLI:** Use the default adapters:

```bash
python <path-to-writing-skills>/scripts/run_eval.py \
  --eval-set <path-to-trigger-eval.json> \
  --skill-path <path-to-skill> \
  --adapter codex-exec

python <path-to-writing-skills>/scripts/improve_description.py \
  --eval-results <path-to-results.json> \
  --skill-path <path-to-skill> \
  --adapter codex
```

`scripts/run_loop.py` combines both with `--trigger-adapter codex-exec --improver-adapter codex`.

**Anthropic-compatible environments:** Use `claude-code` for trigger evals and `anthropic` for description improvement only when those dependencies are actually available and the user wants to exercise that stack:

```bash
python <path-to-writing-skills>/scripts/run_loop.py \
  --eval-set <path-to-trigger-eval.json> \
  --skill-path <path-to-skill> \
  --trigger-adapter claude-code \
  --improver-adapter anthropic
```

**No subagents:** Run test prompts yourself one at a time, using the draft skill as instructions. This is less rigorous than independent runs because you have author context, but it is still useful when paired with human review. Skip baseline comparisons if they would be artificial.

**No browser or display:** Prefer `scripts/generate_review.py --static <output_path>` for a standalone review file, or `--no-open` for server mode without browser launch. If neither is practical, present results directly in the conversation with the prompt, output paths, and a direct request for feedback.

**No quantitative assertions:** Do not force benchmarks onto subjective skills. Use qualitative review, blind comparison when available, and targeted follow-up prompts.

**Packaging:** `scripts/package_skill.py` works anywhere with Python and a filesystem:

```bash
python <path-to-writing-skills>/scripts/package_skill.py <path-to-skill-folder>
```

---

## Reference files

The `references/agents/` directory contains instructions for specialized subagents. Read them when you need to spawn the relevant subagent.

- `references/agents/grader.md` — How to evaluate assertions against outputs
- `references/agents/comparator.md` — How to do blind A/B comparison between two outputs
- `references/agents/analyzer.md` — How to analyze why one version beat another

The references/ directory has additional documentation:
- `references/schemas.md` — JSON structures for evals.json, grading.json, etc.

---

Repeating one more time the core loop here for emphasis:

- Figure out what the skill is about
- Draft or edit the skill
- Choose a validation level
- Run agent-with-skill checks, plus baseline-agent comparisons when the change warrants it
- Put the outputs in front of the user:
  - For substantive multi-run evals, create `benchmark.json` and run `scripts/generate_review.py`
  - For small edits or constrained environments, present the relevant outputs directly
- Use quantitative assertions when the outputs are objectively checkable
- Improve and repeat until you and the user are satisfied
- Package the final skill and return it to the user.

Please add steps to your TodoList, if you have such a thing, to make sure you don't forget. For substantive eval rounds, include "Create evals JSON and run `scripts/generate_review.py` so the human can review test cases."
