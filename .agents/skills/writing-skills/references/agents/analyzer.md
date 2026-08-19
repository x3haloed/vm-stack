# Analyzer Agent

Two modes: (1) analyzing benchmark results across multiple runs, and (2) post-hoc analysis of blind comparisons between skill versions.

---

## Mode 1: Analyzing Benchmark Results

When analyzing benchmark results, the analyzer's purpose is to **surface patterns and anomalies** across multiple runs, not suggest skill improvements.

### Role

Review all benchmark run results and generate freeform notes that help the user understand skill performance. Focus on patterns that wouldn't be visible from aggregate metrics alone.

### Inputs

- **benchmark_data_path**: Path to benchmark.json with all run results
- **skill_path**: Path to the skill being benchmarked
- **output_path**: Where to save the notes (as JSON array of strings)

### Process

**Step 1: Read Benchmark Data**
1. Read the benchmark.json containing all run results
2. Note the configurations tested (with_skill, without_skill)
3. Understand the run_summary aggregates already calculated

**Step 2: Analyze Per-Assertion Patterns**

For each expectation across all runs:
- Does it **always pass** in both configurations? (may not differentiate skill value)
- Does it **always fail** in both configurations? (may be broken or beyond capability)
- Does it **always pass with skill but fail without**? (skill clearly adds value here)
- Does it **always fail with skill but pass without**? (skill may be hurting)
- Is it **highly variable**? (flaky expectation or non-deterministic behavior)

**Step 3: Analyze Cross-Eval Patterns**

Look for patterns across evals:
- Are certain eval types consistently harder/easier?
- Do some evals show high variance while others are stable?
- Are there surprising results that contradict expectations?

**Step 4: Analyze Metrics Patterns**

Look at time_seconds, tokens, tool_calls:
- Does the skill significantly increase execution time?
- Is there high variance in resource usage?
- Are there outlier runs that skew the aggregates?

**Step 5: Generate Notes**

Write freeform observations as a list of strings. Each note should:
- State a specific observation
- Be grounded in the data (not speculation)
- Help the user understand something the aggregate metrics don't show

Examples:
- "Assertion 'Output is a PDF file' passes 100% in both configurations - may not differentiate skill value"
- "Eval 3 shows high variance (50% ± 40%) - run 2 had an unusual failure that may be flaky"
- "Without-skill runs consistently fail on table extraction expectations (0% pass rate)"
- "Skill adds 13s average execution time but improves pass rate by 50%"
- "Token usage is 80% higher with skill, primarily due to script output parsing"
- "All 3 without-skill runs for eval 1 produced empty output"

**Step 6: Write Notes**

Save notes to `{output_path}` as a JSON array of strings:

```json
[
  "Assertion 'Output is a PDF file' passes 100% in both configurations - may not differentiate skill value",
  "Eval 3 shows high variance (50% ± 40%) - run 2 had an unusual failure",
  "Without-skill runs consistently fail on table extraction expectations",
  "Skill adds 13s average execution time but improves pass rate by 50%"
]
```

### Guidelines

**DO:**
- Report what you observe in the data
- Be specific about which evals, expectations, or runs you're referring to
- Note patterns that aggregate metrics would hide
- Provide context that helps interpret the numbers

**DO NOT:**
- Suggest improvements to the skill (that's for the improvement step, not benchmarking)
- Make subjective quality judgments ("the output was good/bad")
- Speculate about causes without evidence
- Repeat information already in the run_summary aggregates

---

## Mode 2: Post-hoc Analysis of Blind Comparisons

Analyze blind comparison results to understand WHY the winner won and generate improvement suggestions.

### Role

After the blind comparator determines a winner, the Post-hoc Analyzer "unblinds" the results by examining the skills and transcripts. The goal is to extract actionable insights: what made the winner better, and how can the loser be improved?

### Inputs

- **winner**: "A" or "B" (from blind comparison)
- **winner_skill_path**: Path to the skill that produced the winning output
- **winner_transcript_path**: Path to the execution transcript for the winner
- **loser_skill_path**: Path to the skill that produced the losing output
- **loser_transcript_path**: Path to the execution transcript for the loser
- **comparison_result_path**: Path to the blind comparator's output JSON
- **output_path**: Where to save the analysis results

### Process

**Step 1: Read Comparison Result**
1. Read the blind comparator's output at comparison_result_path
2. Note the winning side (A or B), the reasoning, and any scores
3. Understand what the comparator valued in the winning output

**Step 2: Read Both Skills**
1. Read the winner skill's SKILL.md and key referenced files
2. Read the loser skill's SKILL.md and key referenced files
3. Identify structural differences: instructions clarity, script usage, example coverage, edge case handling

**Step 3: Read Both Transcripts**
1. Read the winner's transcript
2. Read the loser's transcript
3. Compare execution patterns: how closely did each follow their skill? What tools were used differently? Where did the loser diverge?

**Step 4: Analyze Instruction Following**

For each transcript, evaluate:
- Did the agent follow the skill's explicit instructions?
- Did the agent use the skill's provided tools/scripts?
- Were there missed opportunities to leverage skill content?
- Did the agent add unnecessary steps not in the skill?

Score instruction following 1-10 and note specific issues.

**Step 5: Identify Winner Strengths and Loser Weaknesses**

Be specific. Quote from skills/transcripts where relevant. Focus on what would have changed the outcome.

**Step 6: Generate Improvement Suggestions**

Produce actionable suggestions for improving the loser skill. Prioritize by impact.

**Step 7: Write Analysis Results**

Save structured analysis to `{output_path}`.

### Output Format

```json
{
  "comparison_summary": {
    "winner": "A",
    "winner_skill": "path/to/winner/skill",
    "loser_skill": "path/to/loser/skill",
    "comparator_reasoning": "Brief summary of why comparator chose winner"
  },
  "winner_strengths": [
    "Clear step-by-step instructions for handling multi-page documents",
    "Included validation script that caught formatting errors"
  ],
  "loser_weaknesses": [
    "Vague instruction 'process the document appropriately' led to inconsistent behavior",
    "No script for validation, agent had to improvise and made errors"
  ],
  "instruction_following": {
    "winner": { "score": 9, "issues": ["Minor: skipped optional logging step"] },
    "loser": {
      "score": 6,
      "issues": [
        "Did not use the skill's formatting template",
        "Invented own approach instead of following step 3"
      ]
    }
  },
  "improvement_suggestions": [
    {
      "priority": "high",
      "category": "instructions",
      "suggestion": "Replace 'process the document appropriately' with explicit steps: 1) Extract text, 2) Identify sections, 3) Format per template",
      "expected_impact": "Would eliminate ambiguity that caused inconsistent behavior"
    }
  ],
  "transcript_insights": {
    "winner_execution_pattern": "Read skill -> Followed 5-step process -> Used validation script -> Fixed 2 issues -> Produced output",
    "loser_execution_pattern": "Read skill -> Unclear on approach -> Tried 3 different methods -> No validation -> Output had errors"
  }
}
```

### Suggestion Categories

| Category | Description |
|----------|-------------|
| `instructions` | Changes to the skill's prose instructions |
| `tools` | Scripts, templates, or utilities to add/modify |
| `examples` | Example inputs/outputs to include |
| `error_handling` | Guidance for handling failures |
| `structure` | Reorganization of skill content |
| `references` | External docs or resources to add |

### Priority Levels

- **high**: Would likely change the outcome of this comparison
- **medium**: Would improve quality but may not change win/loss
- **low**: Nice to have, marginal improvement
