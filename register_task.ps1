# Registers Mason's weekday work schedule in Windows Task Scheduler.
# Times are local (this machine is on Eastern Time, matching the market):
#
#   7:30 AM            Mason-Prepare  -- dry-run analysis, logs picks, no orders
#   9:35 AM - 3:35 PM  Mason-Trade    -- live paper trading run every 30 minutes
#   5:00 PM            Mason-WrapUp   -- saves the day's report to logs\reports
#
# confidence_agent.ps1 checks Alpaca's market clock itself, so market holidays
# and early closes are handled there, not here. Re-run this script to update;
# remove everything with: .\register_task.ps1 -Unregister

param([switch]$Unregister)

$taskNames = @("Mason-Prepare", "Mason-Trade", "Mason-WrapUp")

if ($Unregister) {
    foreach ($t in $taskNames) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host "Removed Mason's scheduled tasks."
    exit 0
}

$agent  = Join-Path $PSScriptRoot "confidence_agent.ps1"
$report = Join-Path $PSScriptRoot "mason_report.ps1"
$weekdays = "Monday", "Tuesday", "Wednesday", "Thursday", "Friday"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

function New-PsAction($scriptPath, $scriptArgs) {
    New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $PSScriptRoot `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $scriptArgs"
}

# 7:30 AM: prepare
Register-ScheduledTask -TaskName "Mason-Prepare" -Force -Settings $settings `
    -Action (New-PsAction $agent "-DryRun") `
    -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $weekdays -At "07:30") `
    -Description "Mason pre-market prep: analysis only, no orders." | Out-Null

# 9:35 AM - 3:35 PM: trade every 30 minutes
$tradeTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $weekdays -At "09:35"
$tradeTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At "09:35" `
    -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Hours 6)).Repetition
Register-ScheduledTask -TaskName "Mason-Trade" -Force -Settings $settings `
    -Action (New-PsAction $agent "") -Trigger $tradeTrigger `
    -Description "Mason trading run (paper). Skips itself when the market is closed." | Out-Null

# 5:00 PM: wrap-up report
Register-ScheduledTask -TaskName "Mason-WrapUp" -Force -Settings $settings `
    -Action (New-PsAction $report "-SaveToFile") `
    -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $weekdays -At "17:00") `
    -Description "Mason end-of-day report, saved to logs\reports." | Out-Null

Get-ScheduledTask -TaskName $taskNames | ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo
    [PSCustomObject]@{ Task = $_.TaskName; State = $_.State; NextRun = $info.NextRunTime }
} | Format-Table -AutoSize
