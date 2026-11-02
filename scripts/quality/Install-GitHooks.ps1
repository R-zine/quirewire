[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hook = Join-Path $repositoryRoot '.githooks\pre-commit'
if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
    throw "Missing repository hook: $hook"
}

$git = Get-Command git.exe -ErrorAction Stop
$repositoryForGit = $repositoryRoot.Replace('\', '/')
& $git.Source -c "safe.directory=$repositoryForGit" -C $repositoryRoot config --local core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) {
    throw 'Git refused to configure the repository hooks path.'
}

$configured = (& $git.Source -c "safe.directory=$repositoryForGit" -C $repositoryRoot config --local --get core.hooksPath).Trim()
if ($LASTEXITCODE -ne 0 -or $configured -ne '.githooks') {
    throw "Unexpected core.hooksPath value: '$configured'"
}

Write-Host 'QuireWire Git hooks are enabled for this checkout.'
Write-Host 'Pre-commit runs the complete software-only quality gate; it never runs hardware or paper tests.'
