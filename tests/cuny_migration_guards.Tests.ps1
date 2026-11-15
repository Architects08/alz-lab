$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/Invoke-CunyMigration.ps1"

function New-Change {
    param([string] $Address, [string[]] $Actions)
    @{
        mode = 'managed'
        address = $Address
        change = @{ actions = $Actions }
    }
}

Assert-CreateOnlyPreparation @{
    resource_changes = @(
        (New-Change 'module.cuny_prepare.azapi_resource.policy_assignments["bmcc/example"]' @('create')),
        (New-Change 'module.management_groups[0].azapi_resource.management_groups_level_1["platform"]' @('no-op'))
    )
}

foreach ($unsafe in @(
    (New-Change 'module.cuny_prepare.azapi_resource.management_groups_level_1["bmcc"]' @('delete', 'create')),
    (New-Change 'module.management_groups[0].azapi_resource.management_groups_level_1["platform"]' @('delete', 'create')),
    (New-Change 'module.management_resources.azapi_resource.workspace' @('update'))
)) {
    $rejected = $false
    try {
        Assert-CreateOnlyPreparation @{ resource_changes = @($unsafe) }
    } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "Unsafe preparation plan was accepted: $($unsafe.address)" }
}
Write-Host 'CUNY preparation safety tests passed.'

$events = @(
    (@{ type = 'version'; ui = '1.2' } | ConvertTo-Json -Compress),
    (@{
        type = 'planned_change'
        change = @{
            action = 'create'
            resource = @{
                addr = 'module.cuny_prepare.azapi_resource.policy_assignments["bmcc/example"]'
                module = 'module.cuny_prepare'
                resource_name = 'policy_assignments'
            }
        }
    } | ConvertTo-Json -Compress -Depth 10),
    (@{
        type = 'change_summary'
        changes = @{ add = 1; change = 0; remove = 0; operation = 'plan' }
    } | ConvertTo-Json -Compress)
)
$parsed = ConvertFrom-PreparationEvents $events
if ($parsed.resource_changes.Count -ne 1 -or
    $parsed.resource_changes[0].name -ne 'policy_assignments') {
    throw 'Plan events were not preserved for preparation count validation.'
}
foreach ($invalid in @(
    @{ lines = @($events[0], $events[1]) },
    @{ lines = @($events[0], $events[1], $events[2].Replace('"add":1', '"add":2')) },
    @{ lines = @($events[0], $events[1].Replace('"create"', '"replace"'), $events[2]) },
    @{ lines = @($events[0].Replace('"1.2"', '"2.0"'), $events[1], $events[2]) }
)) {
    $rejected = $false
    try { ConvertFrom-PreparationEvents $invalid.lines | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'An incomplete, mismatched, destructive, or unsupported stream was accepted.' }
}
Write-Host 'CUNY Terraform event validation tests passed.'
