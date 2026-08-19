"""Trigger-evaluation adapters.

Adapters expose the same small surface: given one user query and one skill's
metadata, return whether that harness would invoke/read the skill.
"""

from __future__ import annotations

import os
import json
import shutil
import select
import subprocess
import time
import tempfile
import uuid
from abc import ABC, abstractmethod
from pathlib import Path


class TriggerAdapter(ABC):
    """Base class for skill trigger checks."""

    @abstractmethod
    def run_single_query(
        self,
        query: str,
        skill_name: str,
        skill_description: str,
        timeout: int,
        project_root: Path,
        skill_path: Path | None = None,
        model: str | None = None,
    ) -> bool:
        """Return whether this adapter thinks the skill would trigger."""


class CodexExecTriggerAdapter(TriggerAdapter):
    """Codex adapter using real `codex exec --json` behavior.

    The adapter creates an isolated temporary Codex project, installs the target
    skill under `.codex/skills/<skill-name>/`, runs the user query through
    `codex exec --json`, and inspects the event stream for evidence that the
    agent read the target `SKILL.md` or ran a script from the target skill.
    """

    CODEX_BIN_ENV = "CODEX_TRIGGER_CODEX_BIN"

    def run_single_query(
        self,
        query: str,
        skill_name: str,
        skill_description: str,
        timeout: int,
        project_root: Path,
        skill_path: Path | None = None,
        model: str | None = None,
    ) -> bool:
        del skill_description
        if skill_path is None:
            raise ValueError("Codex exec trigger adapter requires skill_path")

        codex_bin = os.environ.get(self.CODEX_BIN_ENV, "codex")
        source_skill = skill_path.resolve()
        if not (source_skill / "SKILL.md").exists():
            raise ValueError(f"No SKILL.md found at {source_skill}")

        with tempfile.TemporaryDirectory(prefix="codex-skill-trigger-") as tempdir:
            temp_root = Path(tempdir)
            project = temp_root / "project"
            skill_dest = project / ".codex" / "skills" / skill_name
            project.mkdir(parents=True)
            (project / ".codex").mkdir()
            shutil.copytree(
                source_skill,
                skill_dest,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )

            # Ensure project config exists so `.codex/skills` is a repo skill root.
            (project / ".codex" / "config.toml").write_text(
                "[skills]\ninclude_instructions = true\n[skills.bundled]\nenabled = false\n"
            )

            cmd = [
                codex_bin,
                "exec",
                "--json",
                "--ephemeral",
                "--ignore-user-config",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--cd",
                str(project),
            ]
            if model:
                cmd.extend(["--model", model])
            cmd.append(query)

            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=project,
                text=True,
            )
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()

            if process.returncode not in (0, None):
                # Treat command setup/auth failures as non-trigger and include a
                # compact diagnostic for run_eval's warning path.
                raise RuntimeError(stderr.strip() or f"codex exited {process.returncode}")

            target_skill_doc = str((skill_dest / "SKILL.md").resolve())
            target_skill_dir = str(skill_dest.resolve())
            target_scripts_dir = str((skill_dest / "scripts").resolve())
            relative_skill_doc = str((skill_dest / "SKILL.md").relative_to(project))
            relative_skill_dir = str(skill_dest.relative_to(project))
            relative_scripts_dir = str((skill_dest / "scripts").relative_to(project))
            return self._events_show_skill_use(
                stdout,
                skill_name=skill_name,
                target_skill_doc=target_skill_doc,
                target_skill_dir=target_skill_dir,
                target_scripts_dir=target_scripts_dir,
                relative_skill_doc=relative_skill_doc,
                relative_skill_dir=relative_skill_dir,
                relative_scripts_dir=relative_scripts_dir,
            )

    def _events_show_skill_use(
        self,
        stdout: str,
        skill_name: str,
        target_skill_doc: str,
        target_skill_dir: str,
        target_scripts_dir: str,
        relative_skill_doc: str,
        relative_skill_dir: str,
        relative_scripts_dir: str,
    ) -> bool:
        normalized_targets = {
            target_skill_doc,
            target_skill_dir,
            target_scripts_dir,
            relative_skill_doc,
            relative_skill_dir,
            relative_scripts_dir,
        }
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if self._event_mentions_skill(event, skill_name, normalized_targets):
                return True
        return False

    def _event_mentions_skill(
        self,
        event: object,
        skill_name: str,
        normalized_targets: set[str],
    ) -> bool:
        text = json.dumps(event, sort_keys=True)
        text = text.replace("\\/", "/")
        if f"${skill_name}" in text:
            return True
        return any(target in text for target in normalized_targets)


class ClaudeCodeTriggerAdapter(TriggerAdapter):
    """Claude Code adapter using `claude -p` and `.claude/commands`."""

    def run_single_query(
        self,
        query: str,
        skill_name: str,
        skill_description: str,
        timeout: int,
        project_root: Path,
        skill_path: Path | None = None,
        model: str | None = None,
    ) -> bool:
        unique_id = uuid.uuid4().hex[:8]
        clean_name = f"{skill_name}-skill-{unique_id}"
        project_commands_dir = project_root / ".claude" / "commands"
        command_file = project_commands_dir / f"{clean_name}.md"

        try:
            project_commands_dir.mkdir(parents=True, exist_ok=True)
            indented_desc = "\n  ".join(skill_description.split("\n"))
            command_file.write_text(
                "---\n"
                "description: |\n"
                f"  {indented_desc}\n"
                "---\n\n"
                f"# {skill_name}\n\n"
                f"This skill handles: {skill_description}\n"
            )

            cmd = [
                "claude",
                "-p",
                query,
                "--output-format",
                "stream-json",
                "--verbose",
                "--include-partial-messages",
            ]
            if model:
                cmd.extend(["--model", model])

            env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                cwd=project_root,
                env=env,
            )

            triggered = False
            start_time = time.time()
            buffer = ""
            pending_tool_name = None
            accumulated_json = ""

            try:
                while time.time() - start_time < timeout:
                    if process.poll() is not None:
                        remaining = process.stdout.read() if process.stdout else b""
                        if remaining:
                            buffer += remaining.decode("utf-8", errors="replace")
                        break

                    if not process.stdout:
                        break
                    ready, _, _ = select.select([process.stdout], [], [], 1.0)
                    if not ready:
                        continue

                    chunk = os.read(process.stdout.fileno(), 8192)
                    if not chunk:
                        break
                    buffer += chunk.decode("utf-8", errors="replace")

                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        line = line.strip()
                        if not line:
                            continue

                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue

                        if event.get("type") == "stream_event":
                            se = event.get("event", {})
                            se_type = se.get("type", "")

                            if se_type == "content_block_start":
                                cb = se.get("content_block", {})
                                if cb.get("type") == "tool_use":
                                    tool_name = cb.get("name", "")
                                    if tool_name in ("Skill", "Read"):
                                        pending_tool_name = tool_name
                                        accumulated_json = ""
                                    else:
                                        return False

                            elif se_type == "content_block_delta" and pending_tool_name:
                                delta = se.get("delta", {})
                                if delta.get("type") == "input_json_delta":
                                    accumulated_json += delta.get("partial_json", "")
                                    if clean_name in accumulated_json:
                                        return True

                            elif se_type in ("content_block_stop", "message_stop"):
                                if pending_tool_name:
                                    return clean_name in accumulated_json
                                if se_type == "message_stop":
                                    return False

                        elif event.get("type") == "assistant":
                            message = event.get("message", {})
                            for content_item in message.get("content", []):
                                if content_item.get("type") != "tool_use":
                                    continue
                                tool_name = content_item.get("name", "")
                                tool_input = content_item.get("input", {})
                                if tool_name == "Skill" and clean_name in tool_input.get("skill", ""):
                                    triggered = True
                                elif tool_name == "Read" and clean_name in tool_input.get("file_path", ""):
                                    triggered = True
                                return triggered

                        elif event.get("type") == "result":
                            return triggered
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

            return triggered
        finally:
            if command_file.exists():
                command_file.unlink()


def get_trigger_adapter(name: str) -> TriggerAdapter:
    adapters: dict[str, type[TriggerAdapter]] = {
        "codex-exec": CodexExecTriggerAdapter,
        "claude-code": ClaudeCodeTriggerAdapter,
    }
    try:
        return adapters[name]()
    except KeyError as exc:
        valid = ", ".join(sorted(adapters))
        raise ValueError(f"Unknown trigger adapter '{name}'. Valid adapters: {valid}") from exc
