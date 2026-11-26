# Codex Subagent Routing Rules

This environment provides the `codex-subagent` plugin, wrapping the local OpenAI Codex CLI (`codex exec`) for isolated code implementation, multi-file refactoring, deep debugging, and rigorous code review.

## When to Delegate

1. **Explicit-first policy**: Do NOT invoke `codex-subagent` unsolicited on routine or trivial tasks to avoid unnecessary latency and external quota consumption.
2. **Delegate when requested or clearly valuable**:
   - The user explicitly asks to use Codex (e.g., "让 codex 改一下", "交给 codex-subagent 审查").
   - The user requests a cross-review, second opinion, or parallel multi-agent verification.
   - For high-risk refactors or major architectural reviews, you may briefly suggest delegating a second opinion to `codex-subagent` before invoking it.
3. **Prefer `invoke_subagent`**: Dispatch via `invoke_subagent` with `TypeName: "codex-subagent"` so verbose CLI output stays outside the main conversation context.

## Security & Runtime Isolation Guardrails

- **Task-tiered sandbox**:
  - Analysis, review, research, and planning tasks MUST use `-Mode read-only` (the default).
  - Code modification or bug-fix tasks may use `-Mode workspace-write` ONLY when the user explicitly requests file changes.
  - NEVER pass or attempt `danger-full-access` or `--dangerously-bypass-approvals-and-sandbox`.
- **Runtime isolation**: Always invoke through the plugin's bundled `invoke-codex.cmd` wrapper. NEVER run `nvm use` or alter the host Node.js environment to run Codex.
