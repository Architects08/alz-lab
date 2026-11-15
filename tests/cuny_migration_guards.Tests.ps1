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
