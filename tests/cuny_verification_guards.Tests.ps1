$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/Invoke-CunyVerification.ps1"

$baseline = @{
    mode = 'managed'
    type = 'azapi_resource'
    name = 'vnet'
    address = 'module.hub_and_spoke_vnet[0].module.hub_and_spoke_vnet.module.hub_virtual_networks["primary"].azapi_resource.vnet'
    change = @{ actions = @('update') }
}
Assert-FinalCunyPlan @{ resource_changes = @($baseline) }
$replacement = $baseline.Clone()
$replacement.change = @{ actions = @('delete', 'create') }
$governance = @{
    mode = 'managed'
    type = 'azapi_resource'
    name = 'policy_assignments'
    address = 'module.management_groups[0].azapi_resource.policy_assignments["cuny/example"]'
    change = @{ actions = @('update') }
}
foreach ($unsafe in @($replacement, $governance)) {
    $rejected = $false
    try { Assert-FinalCunyPlan @{ resource_changes = @($unsafe) } } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unexpected final-deployment changes were accepted.' }
}
Write-Host 'CUNY final-plan verification tests passed.'
