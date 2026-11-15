$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/Invoke-CunyCutover.ps1"

function New-CutoverChange {
    param([string] $Name, [string] $Key, [string[]] $Actions)
    @{
        mode = 'managed'
        type = 'azapi_resource'
        name = $Name
        key = $Key
        address = "module.management_groups[0].azapi_resource.${Name}[$($Key | ConvertTo-Json -Compress)]"
        change = @{ actions = $Actions }
    }
}

$binding = New-CutoverChange 'policy_assignments' 'platform/example' @('delete', 'create')
$move = New-CutoverChange 'policy_assignments' 'cuny/example' @('move')
$move.previous_address = $move.address.Replace('module.management_groups[0].', 'module.cuny_prepare.')
Assert-CutoverPlan @{
    resource_changes = @(
        (New-CutoverChange 'management_groups_level_2' 'corp' @('delete')),
        (New-CutoverChange 'policy_definitions' 'alz/example' @('delete')),
        $binding,
        $move
    )
} @($binding.address)

$moveEvents = @(
    (@{ type = 'version'; ui = '1.2' } | ConvertTo-Json -Compress),
    (@{
        type = 'planned_change'
        change = @{
            action = 'move'
            resource = @{
                addr = $move.address
                module = 'module.management_groups[0]'
                resource_name = 'policy_assignments'
                resource_type = 'azapi_resource'
                resource_key = 'cuny/example'
            }
            previous_resource = @{ addr = $move.previous_address }
        }
    } | ConvertTo-Json -Depth 10 -Compress),
    (@{
        type = 'change_summary'
        changes = @{ add = 0; change = 0; remove = 0; operation = 'plan' }
    } | ConvertTo-Json -Compress)
)
Assert-CutoverPlan (ConvertFrom-PlanEvents $moveEvents)

$foreignMove = New-CutoverChange 'policy_assignments' 'cuny/example' @('move')
$foreignMove.previous_address = 'module.unrelated.azapi_resource.policy_assignments["cuny/example"]'
$subscription = @{
    mode = 'managed'
    type = 'azapi_resource_action'
    name = 'subscription_placement_create'
    address = 'module.management_groups[0].azapi_resource_action.subscription_placement_create["management"]'
    change = @{ actions = @('delete') }
}
$network = @{
    mode = 'managed'
    type = 'azapi_resource'
    name = 'subnet'
    address = 'module.hub_and_spoke_vnet.azapi_resource.subnet'
    change = @{ actions = @('update') }
}
foreach ($unsafe in @(
    (New-CutoverChange 'management_groups_level_1' 'platform' @('delete')),
    (New-CutoverChange 'management_groups_level_1' 'bmcc' @('delete', 'create')),
    (New-CutoverChange 'policy_definitions' 'cuny/example' @('delete')),
    $foreignMove,
    $subscription,
    $network
)) {
    $rejected = $false
    try { Assert-CutoverPlan @{ resource_changes = @($unsafe) } } catch { $rejected = $true }
    if (-not $rejected) { throw "Unsafe cutover was accepted: $($unsafe.address)" }
}
Write-Host 'CUNY cutover safety tests passed.'

$typedMetadata = @{
    type = 'azapi_resource'
    address = 'module.management_groups[0].azapi_resource.management_groups_level_1["bmcc"]'
    previous_address = 'module.cuny_prepare.azapi_resource.management_groups_level_1["bmcc"]'
    change = @{
        actions = @('update')
        before = @{ body = @{ parent = 'cuny' }; update_headers = @{ telemetry = 'preparation' } }
        after = @{ body = @{ parent = 'cuny' }; update_headers = @{ telemetry = 'final-module' } }
        after_unknown = @{ output = $true }
    }
}
$safe = @(Get-MetadataOnlyUpdates @{ resource_changes = @($typedMetadata) })
if ($safe.Count -ne 1) { throw 'Header-only ownership transfer was not recognized.' }
Assert-CutoverPlan @{
    resource_changes = @(
        (New-CutoverChange 'management_groups_level_1' 'bmcc' @('update'))
    )
} @() $safe
$typedMetadata.change.after.body = @{ parent = 'different-parent' }
if (@(Get-MetadataOnlyUpdates @{ resource_changes = @($typedMetadata) }).Count -ne 0) {
    throw 'A real management-group parent change was misclassified as metadata.'
}
$typedMetadata.change.after.body = @{ parent = 'cuny' }
$typedMetadata.change.after_unknown = @{ body = @{ parent = $true } }
if (@(Get-MetadataOnlyUpdates @{ resource_changes = @($typedMetadata) }).Count -ne 0) {
    throw 'An unknown resource-body change was misclassified as metadata.'
}
Write-Host 'CUNY provider-metadata classification tests passed.'
