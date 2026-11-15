$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Invoke-CunyMigration.ps1"

function Assert-FinalCunyPlan {
    param([hashtable] $Plan)

    $prefix = 'module.hub_and_spoke_vnet[0].'
    $baseline = @(
        'module.virtual_network_gateway["primary-express-route"].azapi_resource.vgw',
        'module.virtual_network_gateway["primary-express-route"].modtm_telemetry.telemetry[0]',
        'module.hub_and_spoke_vnet.module.hub_virtual_network_subnets["primary-bastion"].azapi_resource.subnet[0]',
        'module.hub_and_spoke_vnet.module.hub_virtual_network_subnets["primary-dns_resolver"].azapi_resource.subnet[0]',
        'module.hub_and_spoke_vnet.module.hub_virtual_network_subnets["primary-gateway"].azapi_resource.subnet[0]',
        'module.hub_and_spoke_vnet.module.hub_virtual_network_subnets["primary-nva"].azapi_resource.subnet[0]',
        'module.hub_and_spoke_vnet.module.hub_virtual_networks["primary"].azapi_resource.vnet'
    ) | ForEach-Object { "$prefix$_" }
    $networkDrift = 0
    foreach ($change in $Plan.resource_changes) {
        if ($change.mode -ne 'managed') { continue }
        $action = $change.change.actions -join ','
        if ($change.address -in $baseline -and $action -eq 'update') {
            Write-Warning "Pre-existing networking drift remains unapplied: $($change.address)"
            $networkDrift++
            continue
        }
        if ($change.type -eq 'terraform_data' -and
            $change.module_address -eq 'module.management_groups[0]' -and
            $change.name -in @('policy_assignments_dependencies', 'policy_role_assignments_dependencies') -and
            $action -eq 'update') {
            continue
        }
        throw "Unexpected final plan change: $($change.address) ($action)"
    }
    Write-Host "No pending Azure management-group/governance changes; $networkDrift pre-existing networking changes were not applied."
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $env:MIGRATION_DIRECTORY) { throw 'MIGRATION_DIRECTORY is required.' }
$path = Join-Path $env:MIGRATION_DIRECTORY 'final-verification.tfplan'
$events = & terraform plan -json -input=false -parallelism=1 "-out=$path"
if ($LASTEXITCODE -ne 0) {
    $events | ForEach-Object {
        $event = $_ | ConvertFrom-Json -AsHashtable
        if ($event.type -eq 'diagnostic') {
            Write-Host "$($event.diagnostic.summary): $($event.diagnostic.detail)"
        }
    }
    throw 'Final full-deployment plan failed.'
}
Assert-FinalCunyPlan (ConvertFrom-PlanEvents $events)
