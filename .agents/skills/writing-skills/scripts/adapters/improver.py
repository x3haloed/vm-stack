"""Description-improvement adapters."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from abc import ABC, abstractmethod
from pathlib import Path


class DescriptionImprover(ABC):
    """Base class for skill description improvement."""

    @abstractmethod
    def improve(
        self,
        skill_name: str,
        skill_content: str,
        current_description: str,
        eval_results: dict,
        history: list[dict],
        model: str | None = None,
        test_results: dict | None = None,
        log_dir: Path | None = None,
        iteration: int | None = None,
    ) -> str:
        """Return an improved description."""


def build_improvement_prompt(
    skill_name: str,
    skill_content: str,
    current_description: str,
    eval_results: dict,
    history: list[dict],
    test_results: dict | None = None,
) -> str:
    failed_triggers = [
        r for r in eval_results["results"]
        if r["should_trigger"] and not r["pass"]
    ]
    false_triggers = [
        r for r in eval_results["results"]
        if not r["should_trigger"] and not r["pass"]
    ]

    train_score = f"{eval_results['summary']['passed']}/{eval_results['summary']['total']}"
    if test_results:
        test_score = f"{test_results['summary']['passed']}/{test_results['summary']['total']}"
        scores_summary = f"Train: {train_score}, Test: {test_score}"
    else:
        scores_summary = f"Train: {train_score}"

    prompt = f"""You are optimizing a skill description for an agent skill called "{skill_name}". A skill uses progressive disclosure: the agent sees the skill name and description first, then reads the full skill body only if the metadata suggests it is useful for the user's request.

The description is the main trigger surface. Your goal is to write a description that triggers for relevant requests and avoids irrelevant ones.

Current description:
<current_description>
"{current_description}"
</current_description>

Current scores ({scores_summary}):
<scores_summary>
"""
    if failed_triggers:
        prompt += "FAILED TO TRIGGER (should have triggered but didn't):\n"
        for r in failed_triggers:
            prompt += f'  - "{r["query"]}" (triggered {r["triggers"]}/{r["runs"]} times)\n'
        prompt += "\n"

    if false_triggers:
        prompt += "FALSE TRIGGERS (triggered but shouldn't have):\n"
        for r in false_triggers:
            prompt += f'  - "{r["query"]}" (triggered {r["triggers"]}/{r["runs"]} times)\n'
        prompt += "\n"

    if history:
        prompt += "PREVIOUS ATTEMPTS (do not repeat these; try a structurally different wording if they failed):\n\n"
        for h in history:
            train_s = f"{h.get('train_passed', h.get('passed', 0))}/{h.get('train_total', h.get('total', 0))}"
            test_s = f"{h.get('test_passed', '?')}/{h.get('test_total', '?')}" if h.get("test_passed") is not None else None
            score_str = f"train={train_s}" + (f", test={test_s}" if test_s else "")
            prompt += f"<attempt {score_str}>\n"
            prompt += f'Description: "{h["description"]}"\n'
            if "results" in h:
                prompt += "Train results:\n"
                for r in h["results"]:
                    status = "PASS" if r["pass"] else "FAIL"
                    prompt += f'  [{status}] "{r["query"][:80]}" (triggered {r["triggers"]}/{r["runs"]})\n'
            if h.get("note"):
                prompt += f'Note: {h["note"]}\n'
            prompt += "</attempt>\n\n"

    prompt += f"""</scores_summary>

Skill content:
<skill_content>
{skill_content}
</skill_content>

Write a new description that generalizes from the failures without overfitting to the exact queries. Keep it concise, usually 100-200 words and always under 1024 characters. Focus on user intent and triggering contexts, not the internal workflow.

Respond with only the new description text in <new_description> tags."""
    return prompt


class CodexDescriptionImprover(DescriptionImprover):
    """Codex adapter using `codex exec` with a JSON output schema."""

    CODEX_BIN_ENV = "CODEX_DESCRIPTION_CODEX_BIN"

    def improve(
        self,
        skill_name: str,
        skill_content: str,
        current_description: str,
        eval_results: dict,
        history: list[dict],
        model: str | None = None,
        test_results: dict | None = None,
        log_dir: Path | None = None,
        iteration: int | None = None,
    ) -> str:
        prompt = build_improvement_prompt(
            skill_name=skill_name,
            skill_content=skill_content,
            current_description=current_description,
            eval_results=eval_results,
            history=history,
            test_results=test_results,
        )
        prompt += """

Return JSON only. The response must match this shape:
{"description": "the improved SKILL.md frontmatter description"}
"""
        codex_bin = os.environ.get(self.CODEX_BIN_ENV, "codex")
        schema = {
            "type": "object",
            "additionalProperties": False,
            "required": ["description"],
            "properties": {
                "description": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 1024,
                }
            },
        }

        with tempfile.TemporaryDirectory(prefix="codex-description-improver-") as tempdir:
            temp_root = Path(tempdir)
            schema_path = temp_root / "description.schema.json"
            schema_path.write_text(json.dumps(schema, indent=2))
            cmd = [
                codex_bin,
                "exec",
                "--json",
                "--ephemeral",
                "--ignore-user-config",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--output-schema",
                str(schema_path),
            ]
            if model:
                cmd.extend(["--model", model])
            cmd.append(prompt)

            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=temp_root,
                text=True,
            )
            stdout, stderr = process.communicate()
            if process.returncode != 0:
                raise RuntimeError(stderr.strip() or f"codex exited {process.returncode}")

        final_text = self._extract_final_agent_message(stdout)
        parsed = self._parse_json_object(final_text)
        description = parsed.get("description")
        if not isinstance(description, str):
            raise RuntimeError("Codex response did not include a string 'description'")
        description = description.strip()
        self._validate_description(description)

        if log_dir:
            log_dir.mkdir(parents=True, exist_ok=True)
            log_file = log_dir / f"improve_iter_{iteration or 'unknown'}.json"
            log_file.write_text(json.dumps({
                "adapter": "codex",
                "iteration": iteration,
                "prompt": prompt,
                "stdout": stdout,
                "stderr": stderr,
                "parsed_response": parsed,
                "final_description": description,
            }, indent=2))
        return description

    def _extract_final_agent_message(self, stdout: str) -> str:
        final_message = ""
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") != "item.completed":
                continue
            item = event.get("item", {})
            if item.get("type") == "agent_message":
                final_message = item.get("text", "")
        if not final_message.strip():
            raise RuntimeError("Codex did not emit a final agent_message")
        return final_message.strip()

    def _parse_json_object(self, text: str) -> dict:
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            match = re.search(r"\{[\s\S]*\}", text)
            if not match:
                raise
            value = json.loads(match.group(0))
        if not isinstance(value, dict):
            raise RuntimeError("Codex response was not a JSON object")
        return value

    def _validate_description(self, description: str) -> None:
        if not description:
            raise RuntimeError("Codex returned an empty description")
        if len(description) > 1024:
            raise RuntimeError(f"Codex returned a description over 1024 characters ({len(description)})")
        if "<" in description or ">" in description:
            raise RuntimeError("Codex returned a description containing angle brackets")


class AnthropicDescriptionImprover(DescriptionImprover):
    """Anthropic adapter using the Anthropic Messages API."""

    def improve(
        self,
        skill_name: str,
        skill_content: str,
        current_description: str,
        eval_results: dict,
        history: list[dict],
        model: str | None = None,
        test_results: dict | None = None,
        log_dir: Path | None = None,
        iteration: int | None = None,
    ) -> str:
        if not model:
            raise ValueError("--model is required when using --improver-adapter anthropic")
        try:
            import anthropic
        except ImportError as exc:
            raise RuntimeError(
                "The anthropic package is required for --improver-adapter anthropic"
            ) from exc

        prompt = build_improvement_prompt(
            skill_name=skill_name,
            skill_content=skill_content,
            current_description=current_description,
            eval_results=eval_results,
            history=history,
            test_results=test_results,
        )
        client = anthropic.Anthropic()
        response = client.messages.create(
            model=model,
            max_tokens=16000,
            thinking={"type": "enabled", "budget_tokens": 10000},
            messages=[{"role": "user", "content": prompt}],
        )

        thinking_text = ""
        text = ""
        for block in response.content:
            if block.type == "thinking":
                thinking_text = block.thinking
            elif block.type == "text":
                text = block.text

        description = self._extract_description(text)
        transcript: dict = {
            "adapter": "anthropic",
            "iteration": iteration,
            "prompt": prompt,
            "thinking": thinking_text,
            "response": text,
            "parsed_description": description,
            "char_count": len(description),
            "over_limit": len(description) > 1024,
        }

        if len(description) > 1024:
            shorten_prompt = (
                f"Your description is {len(description)} characters, which exceeds "
                "the hard 1024 character limit. Rewrite it under 1024 characters "
                "while preserving important trigger words. Respond with only the "
                "new description in <new_description> tags."
            )
            shorten_response = client.messages.create(
                model=model,
                max_tokens=16000,
                thinking={"type": "enabled", "budget_tokens": 10000},
                messages=[
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": text},
                    {"role": "user", "content": shorten_prompt},
                ],
            )
            shorten_text = ""
            shorten_thinking = ""
            for block in shorten_response.content:
                if block.type == "thinking":
                    shorten_thinking = block.thinking
                elif block.type == "text":
                    shorten_text = block.text
            description = self._extract_description(shorten_text)
            transcript["rewrite_prompt"] = shorten_prompt
            transcript["rewrite_thinking"] = shorten_thinking
            transcript["rewrite_response"] = shorten_text
            transcript["rewrite_description"] = description
            transcript["rewrite_char_count"] = len(description)

        transcript["final_description"] = description
        if log_dir:
            log_dir.mkdir(parents=True, exist_ok=True)
            log_file = log_dir / f"improve_iter_{iteration or 'unknown'}.json"
            log_file.write_text(json.dumps(transcript, indent=2))
        return description

    def _extract_description(self, text: str) -> str:
        match = re.search(r"<new_description>(.*?)</new_description>", text, re.DOTALL)
        return match.group(1).strip().strip('"') if match else text.strip().strip('"')


def get_description_improver(name: str) -> DescriptionImprover:
    adapters: dict[str, type[DescriptionImprover]] = {
        "codex": CodexDescriptionImprover,
        "anthropic": AnthropicDescriptionImprover,
    }
    try:
        return adapters[name]()
    except KeyError as exc:
        valid = ", ".join(sorted(adapters))
        raise ValueError(f"Unknown description improver '{name}'. Valid adapters: {valid}") from exc
