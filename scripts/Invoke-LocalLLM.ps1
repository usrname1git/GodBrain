[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Prompt,
    [string]$SystemPrompt = "You are a helpful, concise local assistant. For shell questions, give the exact command first, then at most a few sentences explaining it. Do not repeat the question or add unrelated alternatives.",
    [ValidateSet("technical", "personal")][string]$Scope = "technical",
    [switch]$NoSharedMemory,
    [ValidatePattern('^[A-Za-z0-9._:-]{1,128}$')][string]$ThreadId = "desk"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "GodBrain-SharedMemory.ps1")
if ($Prompt.Trim() -match '^(?i)/?index$') {
    $index = Update-GodBrainContextIndex
    return $index.response
}
if (-not $NoSharedMemory -and $Prompt -notmatch '^\s*(?i)no tools\b') {
    if ([string]::IsNullOrWhiteSpace($env:GODBRAIN_API_TOKEN)) {
        throw "Shared memory requires GODBRAIN_API_TOKEN in this process."
    }
    $request = @{
        Uri = "http://127.0.0.1:8083/api/aai"; Method = "Post"
        Headers = @{ Authorization = "Bearer " + $env:GODBRAIN_API_TOKEN }
        ContentType = "application/json; charset=utf-8"
        Body = [Text.Encoding]::UTF8.GetBytes((@{
            message = $Prompt; system_prompt = $SystemPrompt; scope = $Scope; thread_id = $ThreadId
        } | ConvertTo-Json -Compress))
        TimeoutSec = 600; ErrorAction = "Stop"
    }
    try { $result = Invoke-RestMethod @request }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "aai kernel request failed: $detail"
    }
    if ($result.error) { throw "aai failed: $($result.error)" }
    if ($result.response -isnot [string] -or [string]::IsNullOrWhiteSpace($result.response) -or
        $result.shared_saved -ne $true -or $result.shared_record_id -cnotmatch '^[a-f0-9]{64}$' -or
        $result.scope -cne $Scope -or $result.thread_id -cne $ThreadId -or
        $result.request_receipt.tool_attempts -isnot [array]) {
        throw "aai did not return a complete answer with confirmed shared-memory persistence."
    }
    foreach ($attempt in $result.request_receipt.tool_attempts) {
        if ($attempt.executor_ok -isnot [bool] -or -not $attempt.executor_ok) {
            throw "aai reported a failed or invalid tool receipt: $($result.response)"
        }
    }
    return $result.response
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
$body = @{
    model = $model
    messages = @(
        @{ role = "system"; content = $SystemPrompt },
        @{ role = "user"; content = $Prompt }
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
return $answer
