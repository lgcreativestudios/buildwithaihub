# guard-writes.ps1 - refuse file writes outside the project folder.
# Allowed: the project folder, and %USERPROFILE%\.claude\plans (where plan mode saves plans).
# Exit 2 blocks the tool call; the message on stderr is shown to Claude.
try {
  $in = [Console]::In.ReadToEnd() | ConvertFrom-Json
  $path = $in.tool_input.file_path
  if (-not $path) { $path = $in.tool_input.notebook_path }
  if (-not $path) { exit 0 }
  $target = [IO.Path]::GetFullPath($path)
  $allowed = @(
    ([IO.Path]::GetFullPath($env:CLAUDE_PROJECT_DIR).TrimEnd('\') + '\'),
    ([IO.Path]::GetFullPath("$env:USERPROFILE\.claude\plans").TrimEnd('\') + '\')
  )
  foreach ($root in $allowed) {
    if ($target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { exit 0 }
  }
  [Console]::Error.WriteLine("Blocked by project guard: $target is outside $($allowed[0])")
  exit 2
} catch {
  [Console]::Error.WriteLine("Project guard failed, so the write is blocked: $($_.Exception.Message)")
  exit 2
}