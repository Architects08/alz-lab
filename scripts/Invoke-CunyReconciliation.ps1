param(
    [ValidateSet('reconcile-plan', 'reconcile-apply')]
    [string] $ReconciliationStage = 'reconcile-plan'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Invoke-CunyCutover.ps1"

if (-not $env:MIGRATION_DIRECTORY) { throw 'MIGRATION_DIRECTORY is required.' }
$retained = @('platform', 'sandbox', 'alz-lab-decommissioned')
$addresses = @($retained | ForEach-Object {
    'module.management_groups[0].azapi_resource.management_groups_level_1[' +
        ($_ | ConvertTo-Json -Compress) + ']'
})
$blocks = foreach ($group in $retained) {
    $address = 'module.management_groups[0].azapi_resource.management_groups_level_1[' +
        ($group | ConvertTo-Json -Compress) + ']'
    "import {`n  to = $address`n  id = `"/providers/Microsoft.Management/managementGroups/${group}?api-version=2023-04-01`"`n}"
}
($blocks -join "`n`n") | Set-Content 'cuny_retained_imports.tf'
@'
module "management_groups" {
  policy_assignments_dependencies      = []
  policy_role_assignments_dependencies = []
}
'@ | Set-Content 'cuny_cutover_override.tf'

$path = Join-Path $env:MIGRATION_DIRECTORY 'retained-imports.tfplan'
$arguments = @('plan', '-input=false', '-no-color', "-out=$path")
foreach ($address in $addresses) { $arguments += "-target=$address" }
Invoke-TerraformChecked $arguments
$plan = Get-CutoverTypedPlan $path
$metadata = @(Get-MetadataOnlyUpdates $plan)
$imports = 0
foreach ($change in $plan.resource_changes) {
    if ($change.mode -ne 'managed') { continue }
    if ($change.change.importing) {
        if ($change.address -notin $addresses) {
            throw "Unexpected import: $($change.address)"
        }
        $imports++
    }
    $actions = $change.change.actions -join ','
    if ($actions -eq 'no-op') { continue }
    if ($change.address -notin $addresses -or $actions -ne 'update' -or
        $change.address -notin $metadata) {
        throw "Reconciliation must only import retained groups and initialize metadata: $($change.address)"
    }
}
Write-Host "Verified retained-group reconciliation: $imports imports, metadata-only updates, no Azure body changes or deletions."
if ($ReconciliationStage -eq 'reconcile-apply') {
    Invoke-TerraformChecked @('apply', '-input=false', '-no-color', $path)
}
