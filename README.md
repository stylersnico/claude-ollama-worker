# claude-ollama-worker

Let Claude Code plan and review, and let an open-source model on Ollama write the code.

`local-worker.ps1` takes one precise coding task, runs it with [aider](https://aider.chat) (or Claude Code headless) against an Ollama model, inside a dedicated git branch and worktree. Claude, or you, then reviews the diff, tests and merges. Nothing lands on your branch without a review.

Why:

- **Cost**: the code is written by a local open-source model, Claude only spends tokens on the task description and the review.
- **Review by design**: every change arrives as a separate branch with one commit.
- **Privacy**: with a local or LAN Ollama server, the code never leaves your network.

## How it works

```
Claude Code (or you)
   |  writes a precise task: goal, files, exact changes, "change nothing else", done criteria
   v
local-worker.ps1 <name> "<task>" <files>
   |  1. picks a backend: remote Ollama server, else local Ollama (NVIDIA GPU only)
   |  2. creates branch local/<name> in a separate worktree (../.worktrees/<repo>-<name>)
   |  3. runs aider with the model on the given files
   |  4. commits the result on local/<name>
   v
git diff main...local/<name>   ->  review, test
git merge --no-ff local/<name> ->  then remove the worktree and the branch
```

### Backend selection

| Order | Backend | Condition |
|---|---|---|
| 1 | Remote Ollama server (`OLLAMA_REMOTE_URL`) | default `-m std` (or `-m alt`), and the server answers on `/api/tags` |
| 2 | Local Ollama | no remote server, and `nvidia-smi` answers |
| opt-in | Ollama Cloud (`WORKER_MODEL_CLOUD`, default `gpt-oss:120b-cloud`) | only with `-m cloud`; a 1-token request checks the quota first, falls back to `std` if refused |

Without a remote server and without an NVIDIA GPU, the script stops (exit 3) instead of running a 20 GB model on the CPU.

### Why the default is no longer Ollama Cloud

The first version used Ollama Cloud (`gpt-oss:120b-cloud`) by default, because the free plan gave enough quota for this kind of small, precise task. My free cloud access ends on November 9, 2026, so the default is now a self-hosted model: a LAN Ollama server running `qwen3-coder:30b`.

It is slower (my server is a laptop with a 4 GB GPU, so the model runs mostly on the CPU and tasks go to the background), but it costs nothing, has no quota, and the code never leaves the network. Ollama Cloud is still available with `-m cloud` if you have a plan with cloud quota.

## Requirements

- Windows with PowerShell 5.1 or 7
- [git](https://git-scm.com)
- [Ollama](https://ollama.com) on a LAN server (recommended) or on a PC with an NVIDIA GPU; `ollama signin` only if you use `-m cloud`
- [aider](https://aider.chat): `python -m pip install aider-install; aider-install`
- Optional: Python 3, for the logging proxy

## Installation

```powershell
git clone https://github.com/stylersnico/claude-ollama-worker "$env:USERPROFILE\bin\claude-ollama-worker"
# on the Ollama server:
ollama pull qwen3-coder:30b
```

Optional configuration, for example in your PowerShell profile:

```powershell
$env:OLLAMA_REMOTE_URL  = 'http://192.168.1.50:11434'   # LAN Ollama server, unset = none
$env:WORKER_MODEL_STD   = 'qwen3-coder:30b'             # standard coding model
$env:WORKER_MODEL_ALT   = ''                            # optional fallback model
$env:WORKER_MODEL_CLOUD = 'gpt-oss:120b-cloud'
```

Avoid very small models (3B and below): they are too weak for real code.

## Usage

Run it from inside the git repository you want to change:

```powershell
local-worker.ps1 -e aider fix-encoding "In md2docx.py, replace the Unicode characters in every print() with ASCII equivalents. Change nothing else. Done when every print() in md2docx.py is ASCII only." md2docx.py
```

| Option | Values | Default |
|---|---|---|
| `-e` | `aider`, `claude` | `aider` |
| `-m` | `cloud`, `std`, `alt` | `cloud` |
| `<name>` | branch suffix, `local/<name>` | required |
| `<task>` | the task, in one string | required |
| `[files...]` | files aider may edit | none |

Then review and merge:

```powershell
git diff main...local/fix-encoding
git merge --no-ff local/fix-encoding
git worktree remove ..\.worktrees\<repo>-fix-encoding
git branch -d local/fix-encoding
```

If the diff is wrong, run the script again with the same `<name>` and a correction task: it reuses the branch and adds a commit.

### Writing a good task

One task, one goal. Give the model:

1. the files to change (pass them as arguments to aider);
2. the exact changes expected;
3. "change nothing else";
4. the done criteria, ideally a command that must succeed.

Engine choice: `aider` is recommended. Claude Code headless on top of gpt-oss tended to spawn sub-worktrees of its own and ask questions instead of editing.

## Using it from Claude Code

Add the rules to your global `%USERPROFILE%\.claude\CLAUDE.md`, so every session delegates instead of coding. A trimmed example:

```markdown
## Delegation of development to Ollama models

- Claude does not write or modify code itself: no "small fix", no exception.
- Claude only reads, analyzes, writes precise tasks, reviews diffs, runs tests and merges.
- Model: the LAN Ollama server (qwen3-coder:30b), or local Ollama only if an NVIDIA GPU is present.
  If neither answers, no delegation: report to the user and propose options.
- Use %USERPROFILE%\bin\claude-ollama-worker\local-worker.ps1 with -e aider and the files to edit.
- One task = one goal, the files, the exact changes, "change nothing else", the done criteria.
- Always review `git diff main...local/<name>`. If wrong, send a correction task to the model
  (do not fix it yourself). Then test, `git merge --no-ff`, remove the worktree and the branch.
```

For a project where you want Claude to code directly, add an exception in that project's `CLAUDE.md`.

## Logs

- `~/.local/state/local-worker/tasks.jsonl`: one line per task (time, name, model, engine, task)
- `~/.local/state/local-worker/worker.log`: transcript of every run
- `~/.local/state/local-worker/exchanges.jsonl`: every prompt and answer, when the logging proxy runs

`ollama-logproxy.py` is a transparent proxy on `127.0.0.1:11435` in front of the local Ollama. The worker starts it automatically if Python is available and routes local and cloud requests through it. Requests to a remote server bypass it.

## License

MIT
