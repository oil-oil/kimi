---
name: kimi
description: Delegate design-heavy UI/UX work, frontend implementation, coding, repository exploration, review, and media-aware analysis to the local Kimi Code CLI through a bundled non-interactive wrapper. Kimi is a design-strong Agent suited to visual direction, design systems, interface critique, and frontend polish. It can inspect local images and videos but cannot generate or edit image assets. Invoke only when the user explicitly asks to use Kimi or Kimi Code, such as "用 Kimi 做", "让 Kimi 执行", or "ask Kimi to...". Use for new or resumed Kimi sessions, local model selection, priority file or media hints, analysis, and implementation work in trusted workspaces; do not use it for image generation.
---

# Kimi

## Core rules

- Use `scripts/ask_kimi.sh` instead of invoking `kimi -p` directly. The wrapper captures Kimi's JSONL, streams compact progress, records the session ID, and writes a Markdown result.
- Run the wrapper once per task. After success, read the reported `output_path` and inspect the workspace before deciding whether a follow-up is needed.
- Give Kimi the goal, completion criteria, constraints, and non-obvious context. Keep delegated prompts focused, normally under 500 words.
- Pass 1-4 useful entry points with `--file`; Kimi can discover the rest. File hints may point to code, images, or videos that Kimi can inspect with its local tools.
- Treat Kimi as a design-strong coding Agent. Prefer it for UI/UX critique, visual direction, layout and typography decisions, design-system work, and polished frontend implementation.
- Do not ask Kimi to generate or edit image assets. It can analyze screenshots, images, and videos and then express its design decisions as specifications or frontend code, but it cannot create the image itself. Use an image-generation or image-editing tool when the requested deliverable is an image.
- Quote paths containing spaces, brackets, or shell metacharacters.
- Do not mention this Skill or its wrapper implementation in the delegated prompt.

## Host compatibility

Use this Skill from any Agent that can load `SKILL.md` instructions and execute a local shell command. The wrapper is host-agnostic: it communicates with Kimi Code through its CLI and does not call a host-specific API. `agents/openai.yaml` is optional metadata for OpenAI hosts; other Agents may ignore it.

## Safety boundary

Kimi's non-interactive prompt mode uses its automatic permission policy and may edit files or run commands. Use it only in a trusted workspace and only when the user's request authorizes those changes.

`kimi -p` cannot be combined with Kimi's `--plan` flag and provides no filesystem sandbox for non-interactive prompt mode. Therefore, this wrapper intentionally has no `--read-only` option. For enforced no-write exploration, use interactive `kimi --plan` in the user's terminal or another sandboxed mechanism; do not describe a prompt-only instruction as a read-only guarantee.

## Wrapper path

```text
<skill-directory>/scripts/ask_kimi.sh
```

## Usage

Run a task in the current workspace:

```bash
./scripts/ask_kimi.sh "Implement the requested change"
```

Add priority files and an explicit workspace:

```bash
./scripts/ask_kimi.sh "Refactor these components to use the new API" \
  --workspace "/path/to/repo" \
  --file "src/components/UserList.tsx" \
  --file "src/components/UserDetail.tsx"
```

Use Kimi's design judgment with a screenshot reference:

```bash
./scripts/ask_kimi.sh "Review this interface and implement a more polished layout" \
  --file "references/current-ui.png" \
  --file "src/App.tsx"
```

This asks Kimi to inspect the screenshot and improve the implementation; it does not ask Kimi to generate an image.

Use a locally configured model alias:

```bash
./scripts/ask_kimi.sh "Review the active request path" \
  --model "kimi-code/kimi-for-coding"
```

Resume a previous session:

```bash
./scripts/ask_kimi.sh "Also add the missing regression test" \
  --session <session_id>
```

Allow Kimi to access another directory:

```bash
./scripts/ask_kimi.sh "Compare the app with the shared package" \
  --add-dir "/path/to/shared-package"
```

## Workflow

1. Read enough local context to state the actual goal and important constraints.
2. Choose the workspace, optional model, and 1-4 priority files.
3. Run the wrapper with one focused prompt.
4. Read the Markdown file printed as `output_path`.
5. Review workspace changes and run verification proportional to risk.
6. Use `--session` only for a true follow-up that benefits from Kimi's prior context.

## Output

Successful runs print:

```text
session_id=<kimi_session_id>
output_path=<absolute_markdown_path>
elapsed=<seconds>s
```

The Markdown file contains Kimi's final response, a compact list of tools used, and elapsed time. Raw tool results and arguments are intentionally omitted to keep the handoff concise and reduce accidental secret exposure.

## Options

- `--workspace <path>`: working directory; defaults to the current directory.
- `--file <path>`: priority file or media hint; repeatable.
- `--session <id>`: resume a previous Kimi session.
- `--model <alias>`: model alias configured in Kimi Code.
- `--add-dir <path>`: add an accessible workspace directory; repeatable.
- `--skills-dir <path>`: replace Kimi's auto-discovered Skill directories for this run; repeatable.
- `--output <path>`: choose the Markdown result path.

Task text may be passed as the first positional argument, with `--task`, or through stdin.

## Failure handling

- If `kimi` is unavailable, run `kimi --version` and check the local installation.
- If authentication or configuration fails, run `kimi doctor`; use `kimi login` when authentication is missing.
- If a flag stops working after an upgrade, inspect `kimi --help` and update the wrapper rather than assuming compatibility with another Agent CLI.
- A non-zero Kimi exit is treated as failure. Exit code `3` means a goal blocked and `6` means a goal paused on versions that support goal mode.
- Kimi warnings remain captured for diagnostics; failure output is truncated and common token patterns are redacted.
