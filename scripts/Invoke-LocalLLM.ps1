[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Prompt,
    [string]$SystemPrompt = "You are a helpful, concise local assistant. For shell questions, give the exact command first, then at most a few sentences explaining it. Do not repeat the question or add unrelated alternatives.",
    [ValidateSet("technical", "personal")][string]$Scope = "technical",
    [switch]$NoSharedMemory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "GodBrain-SharedMemory.ps1")
if ($Prompt.Trim() -match '^(?i)/?index$') {
    $index = Update-GodBrainContextIndex
    return $index.response
}
$memory = $null
if (-not $NoSharedMemory -and $Prompt -notmatch '^\s*(?i)no tools\b') {
    $memory = Get-GodBrainSharedContext -Query $Prompt -Scope $Scope
}
$uri = "http://127.0.0.1:8888"
$health = Invoke-RestMethod -Uri "$uri/health" -TimeoutSec 3
if ($health.backend -cne "exl3" -or $health.busy) {
    throw "The EXL3 service must already be running and idle. No model was started."
}
$models = Invoke-RestMethod -Uri "$uri/v1/models" -TimeoutSec 3
$model = [string]$models.data[0].id
if ([string]::IsNullOrWhiteSpace($model) -or $model -cne $health.model) {
    throw "Qwen model discovery was invalid or the active model changed. Try again."
}
$user = if ($null -ne $memory) { Add-GodBrainSharedContext $Prompt $memory } else { $Prompt }
$body = @{
    model = $model
    messages = @(
        @{ role = "system"; content = $SystemPrompt },
        @{ role = "user"; content = $user }
    )
    temperature = 0.7
    max_tokens = 2048
    chat_template_kwargs = @{ enable_thinking = $false }
    stream = $false
    tool_choice = "none"
} | ConvertTo-Json -Depth 10
$response = Invoke-RestMethod -Uri "$uri/v1/chat/completions" -Method Post `
    -ContentType "application/json; charset=utf-8" -Body $body -TimeoutSec 180
if ($response.error -or @($response.choices).Count -ne 1) {
    throw "Qwen returned an invalid completion or an API error."
}
$choice = $response.choices[0]
if ($choice.finish_reason -cne "stop") {
    throw "Qwen did not finish the answer (finish_reason='$($choice.finish_reason)', completion_tokens=$($response.usage.completion_tokens), requested_max_tokens=2048)."
}
$answer = $choice.message.content
if ($choice.message.tool_calls -or $answer -isnot [string] -or [string]::IsNullOrWhiteSpace($answer)) {
    throw "Qwen returned no plain-text answer."
}
if ($null -ne $memory) {
    try { $null = Save-GodBrainWorkingTurn -Prompt $Prompt -Response $answer -Scope $Scope }
    catch {
        throw "The answer was generated but shared persistence failed; it was not confirmed saved. $($_.Exception.Message)`n`nAnswer:`n$answer"
    }
}
return $answer
