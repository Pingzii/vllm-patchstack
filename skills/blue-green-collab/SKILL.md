---
name: blue-green-collab
description: Use when code or experiments must move between a network-connected "blue" zone / transfer host and an isolated "green" zone (air-gapped NPU/GPU cluster), i.e. when the user wants to ship patches into the green zone, run an experiment there, and get a minimal result back without hand-editing code. Covers the one-way patch-stack transport, the green-zone runbook, the report contract, and the compliance red lines (green zone is read-only). Do not use for ordinary local development in a single machine, for upstream PR workflows, or for anything that requires the green zone to push, upload, or otherwise send data outward.
---

# Blue/green zone collaboration

Move **code in one way, results out as one line**. The green zone never writes
outward. Nothing is ever hand-edited or copy-pasted as code.

## Roles

| Role | Where | May do | Must never do |
|---|---|---|---|
| **Blue / transfer host** | workstation with internet + this agent | edit patches, `git push` to the patch-stack repo, read back the reported line | assume the green zone can reach the internet or hold credentials |
| **Green zone** | isolated cluster checkout (e.g. the pinned vllm-ascend tree) | `git clone/fetch` the patch-stack repo, apply patches locally, run, revert | `git push`, upload, or exfiltrate anything; keep git state behind |

The patch-stack repo (default `https://github.com/Pingzii/vllm-patchstack.git`) is the
only transport. It contains **changes only** — never a full tree — so the
staleness of any fork is irrelevant.

## Hard boundaries

- **Green zone is read-only.** Only `git clone/fetch`, local file edits, local
  processes, and `/tmp` writes are allowed. Any push/upload from it is a
  compliance violation.
- **Never `git checkout` an umbrella branch in the green zone.** A debug branch
  based on an old fork would silently downgrade the whole worktree. Fetch, then
  extract only the needed directory (`git archive FETCH_HEAD <dir> | tar -x`),
  or clone the patch-stack repo into `/tmp` and delete its `.git`.
- **Never write to the user's working tree without a revert path.** Every
  applied change must be undoable by one command (`revert_all.sh`).
- **Egress is one short line.** Do not ask the user to paste code, whole logs,
  or multi-process transcripts. Ask for the `FINGERPRINT:` line (see
  [`references/report-contract.md`](references/report-contract.md)), optionally
  plus a ≤5-line excerpt of the first error.
- **One variable per experiment**, and the caller must state what changed
  relative to the previous run.
- **Do not silently change the green zone's baseline.** Patches apply on top of
  the green-zone checkout; if `git apply --check` fails, stop and rebase the
  patch instead of editing the file in place on the green side.

## Workflow

### Phase 0 — establish the environment picture (once per session)

Collect, and write into the patch-stack `README.md`: model + quantization,
SOC/cards, the *working baseline* configuration, the pinned vllm-ascend/vLLM
commits, the patch-stack URL, and whether the green zone can push (it cannot).
If any of these is missing, ask before designing anything.

### Phase 1 — author the change on the blue side

1. Put diff-shaped changes in `patches/<repo>/NNNN-<slug>.patch`; put
   one-shot/diagnostic changes in `debug/` as scripts that are **idempotent,
   anchor-checked, and `--revert`-able**.
2. Register every item in `manifest.tsv` (`repo<TAB>kind<TAB>path<TAB>desc`).
3. Verify locally before shipping: `bash -n` each script,
   `python -m py_compile` each module, and the anchor text must occur exactly
   once in the target file.

### Phase 2 — publish (blue side, needs the agent's shell)

```powershell
pwsh -File scripts\blue_publish.ps1            # clone, copy, commit -s, push
```

Sanity-check afterwards: the repo tree must contain `.gitignore`, no
`__pycache__`, and the expected `patches/`/`debug/`/`skills/` entries.

### Phase 3 — run (green side, one command)

```bash
bash /tmp/patchstack/scripts/green_run.sh      # sync → apply → run → report → revert
```

`green_run.sh` auto-discovers the repo root, prints the resolved versions, and
finishes with a single `FINGERPRINT:` line. Add `--keep` to leave the patch
applied for manual poking, `--revert` to only undo.

### Phase 4 — report back

Ask for **only** the `FINGERPRINT:` line (and the first error line if
everything failed). Then update `manifest.tsv`/`README.md`, write the real fix
as `patches/<repo>/NNNN-*.patch`, and repeat from Phase 2.

### Phase 5 — promote

Once a fix is verified with a numeric check (same greedy prompts produce
token-identical output on the baseline path), open a normal branch for upstream
with tests + `Signed-off-by`. The debug entry stays in `debug/` and is never
part of the upstream PR.

## Automation contract

**Everything is per task.** A task is a directory `tasks/<task-id>/` holding its own
`manifest.tsv`, `patches/` and `debug/`; the scripts take `--task <id>` and refuse to
guess when several tasks exist. Read
[`references/multi-task.md`](references/multi-task.md) before running more than one
task in the same week — one experiment runs exactly one task, results and reports are
namespaced by task id, and the report line is `FINGERPRINT <task-id>: ...`.

| Script | Side | Purpose |
|---|---|---|
| `scripts/blue_publish.ps1` | blue | publish patch stack (all tasks) + this skill |
| `scripts/green_bootstrap.sh` | green | print/install the aliases (`dsv4sync/dsv4run/dsv4back`) |
| `scripts/green_run.sh` | green | whole green-side loop for one task: `--task <id>` |
| `apply_all.sh` / `revert_all.sh` | both | apply/revert one task's manifest: `--task <id>` |

Exit codes: `0` success, `2` misuse/missing input, non-zero from a script means
that patch failed (`git apply --check` mismatch) — report it, do not work around
it by editing the target file.

## Reporting rules for the agent

- State every conclusion as **fact (proven by the log) / inference (with basis)
  / open (and how to falsify)**.
- Never claim a capability you have not tested. If a command is denied by the
  sandbox, retry once with wider sandbox permissions before declaring it
  impossible.
- Name the precondition of every proposed fix (env var, config gate, version),
  because "the config is written" does not mean "the code path is taken".
