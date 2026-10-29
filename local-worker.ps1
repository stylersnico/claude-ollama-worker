<#
local-worker.ps1 - delegate a precise coding task to an Ollama model, on a dedicated git branch.
Usage : local-worker.ps1 [-e aider|claude] [-m cloud|std|alt] <name> "<precise task>" [files... (aider)]
  -e aider (default) : aider, files to edit passed explicitly (shorter prompt, faster on CPU)
  -e claude          : Claude Code headless pointed at Ollama
  -m cloud (default) : Ollama Cloud model; falls back to std if the quota is exhausted
  -m std             : standard local/remote coding model
  -m alt             : alternative model, only if std refuses a legitimate task
Order of backends : Ollama Cloud -> remote Ollama server (OLLAMA_REMOTE_URL) -> local Ollama (only with an NVIDIA GPU).
Result : a commit on branch local/<name>, in a separate worktree. Review, then merge.

Configuration (environment variables, all optional) :
  WORKER_MODEL_CLOUD  default gpt-oss:120b-cloud
  WORKER_MODEL_STD    default qwen3-coder:30b
  WORKER_MODEL_ALT    no default (e.g. an abliterated model)
  OLLAMA_REMOTE_URL   e.g. http://192.168.1.50:11434 ; unset = no remote server
#>
param(
  [Alias('e')][ValidateSet('claude','aider')][string]$Engine = 'aider',
  [Alias('m')][ValidateSet('cloud','std','alt')][string]$Kind = 'cloud',
  [Parameter(Position=0, Mandatory)][string]$Name,
  [Parameter(Position=1, Mandatory)][string]$Task,
  [Parameter(Position=2, ValueFromRemainingArguments)][string[]]$Files
)
$ErrorActionPreference = 'Stop'
function Get-Env($n, $d) { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $v } else { $d } }
$Models = @{
  cloud = Get-Env 'WORKER_MODEL_CLOUD' 'gpt-oss:120b-cloud'
  std   = Get-Env 'WORKER_MODEL_STD' 'qwen3-coder:30b'
  alt   = Get-Env 'WORKER_MODEL_ALT' ''
}
$Model = $Models[$Kind]
if (-not $Model) { Write-Host ">> No model configured for -m $Kind (set WORKER_MODEL_ALT)."; exit 2 }
$LocalUrl = 'http://127.0.0.1:11434'

# Cloud : check the quota with a 1-token request, otherwise fall back to the standard model
if ($Kind -eq 'cloud') {
  $probe = @{ model = $Model; stream = $false; options = @{ num_predict = 1 }; messages = @(@{ role = 'user'; content = 'ok' }) } | ConvertTo-Json -Depth 5
  try { Invoke-RestMethod -Uri "$LocalUrl/api/chat" -Method Post -Body $probe -ContentType 'application/json' -TimeoutSec 60 | Out-Null }
  catch { Write-Host ">> $Model unavailable (quota?) : falling back to $($Models.std)"; $Kind = 'std'; $Model = $Models.std }
}

# Remote Ollama server (preferred over the local GPU for non-cloud models)
$RemoteUrl = Get-Env 'OLLAMA_REMOTE_URL' ''
$Remote = $false
if ($Kind -ne 'cloud' -and $RemoteUrl) {
  try { Invoke-RestMethod "$RemoteUrl/api/tags" -TimeoutSec 3 | Out-Null; $Remote = $true; Write-Host ">> Remote server $RemoteUrl : $Model" } catch {}
}

# Local model : only with an NVIDIA GPU that answers (a 20 GB model on CPU is painfully slow)
function Test-Nvidia {
  if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $false }
  nvidia-smi *> $null; $LASTEXITCODE -eq 0
}
if ($Kind -ne 'cloud' -and -not $Remote -and -not (Test-Nvidia)) {
  Write-Host ">> No remote server and no NVIDIA GPU (nvidia-smi) : local delegation impossible with $Model."; exit 3
}

$Repo = git rev-parse --show-toplevel; if ($LASTEXITCODE) { exit 2 }
$Base = git -C $Repo rev-parse --abbrev-ref HEAD
$Branch = "local/$Name"
$Wt = Join-Path (Split-Path $Repo) ".worktrees\$(Split-Path $Repo -Leaf)-$Name"
New-Item -ItemType Directory -Force (Split-Path $Wt) | Out-Null
if (-not (Test-Path $Wt)) {
  git -C $Repo worktree add -q -b $Branch $Wt $Base 2>$null
  if ($LASTEXITCODE) { git -C $Repo worktree add -q $Wt $Branch; if ($LASTEXITCODE) { exit 1 } }
}
Set-Location $Wt
Write-Host ">> [$Model via $Engine] $Task  (branch $Branch, base $Base)"

# Task journal (same folder as ollama-logproxy.py)
$StateHome = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $HOME '.local\state' }
$LogDir = Join-Path $StateHome 'local-worker'; New-Item -ItemType Directory -Force $LogDir | Out-Null
[ordered]@{ ts = (Get-Date -Format 'HH:mm:ss'); name = $Name; model = $Model; engine = $Engine; task = $Task } |
  ConvertTo-Json -Compress | Add-Content -Encoding utf8 (Join-Path $LogDir 'tasks.jsonl')
Start-Transcript -Append -Path (Join-Path $LogDir 'worker.log') | Out-Null

# Optional logging proxy (port 11435) ; direct 11434 if unavailable
function Test-Proxy { try { Invoke-RestMethod http://127.0.0.1:11435/api/version -TimeoutSec 1 | Out-Null; $true } catch { $false } }
$OllamaUrl = $LocalUrl
if (-not (Test-Proxy)) {
  $py = (Get-Command pythonw, python, py -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  $proxy = Join-Path $PSScriptRoot 'ollama-logproxy.py'
  if ($py -and (Test-Path $proxy)) { Start-Process $py -ArgumentList "`"$proxy`"" -WindowStyle Hidden; Start-Sleep -Milliseconds 800 }
}
if (Test-Proxy) { $OllamaUrl = 'http://127.0.0.1:11435' }
if ($Remote) { $OllamaUrl = $RemoteUrl }  # the logging proxy only relays to 127.0.0.1

try {
  switch ($Engine) {
    'claude' {
      $env:ANTHROPIC_BASE_URL = $OllamaUrl; $env:ANTHROPIC_AUTH_TOKEN = 'ollama'; $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
      claude -p --model $Model --permission-mode acceptEdits $Task
    }
    'aider' {
      $env:OLLAMA_API_BASE = $OllamaUrl
      aider --model "ollama_chat/$Model" --yes-always --no-auto-commits --no-show-model-warnings --no-check-update --message $Task @Files
    }
  }
  if ($LASTEXITCODE) { Write-Host ">> $Engine exited with code $LASTEXITCODE" }

  git add -A
  git diff --cached --quiet
  if ($LASTEXITCODE -eq 0) { Write-Host '>> No change produced.' } else { git commit -q -m "local(${Model}): $Task" }
  Write-Host ">> Branch : $Branch   Worktree : $Wt"
  git --no-pager diff --stat "$Base...HEAD"
  Write-Host ">> Review : git diff $Base...$Branch"
  Write-Host ">> Merge  : git merge --no-ff $Branch; git worktree remove '$Wt'; git branch -d $Branch"
} finally { Stop-Transcript | Out-Null }
