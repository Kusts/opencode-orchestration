$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$writers = @('ai-agent-engineer','automation-engineer','backend-engineer','coder','database-engineer','docs-manager','frontend-engineer','infra-engineer')
$readers = @('architect','debugger','engineering-advisor','explorer','product-designer','requirements-analyst','researcher','reviewer','security-reviewer','skeptic','tester')
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($name in ($writers + $readers)) {
  $path = Join-Path $RepoRoot "source\agents\$name.md"
  $text = Get-Content -Raw $path
  $frontmatter = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---').Groups[1].Value
  $expectedEdit = if ($writers -contains $name) { 'allow' } else { 'deny' }
  if ($frontmatter -notmatch "(?m)^  edit: $expectedEdit\r?$") { $failures.Add("$name edit expected $expectedEdit") }
  if ($frontmatter -notmatch '(?m)^  bash:\r?\n    "\*": allow\r?$') { $failures.Add("$name missing bash catch-all allow") }
  if ($frontmatter -match '(?ms)^  bash:\r?\n(?:(?!^  task:).)*^\s+["''][^"'']+["'']:\s+(deny|ask)\r?$') { $failures.Add("$name has legacy shell deny/ask rule") }
  if ($frontmatter -notmatch '(?m)^  task: deny\r?$') { $failures.Add("$name missing task deny") }
}

if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "NOT OK - $_" }
  exit 1
}
Write-Host "PASS: 19 agent permission frontmatters match shell-free policy; edit and task boundaries preserved."
