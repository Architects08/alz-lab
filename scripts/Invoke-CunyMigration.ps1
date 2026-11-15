param(
    [ValidateSet('prepare-plan', 'prepare-apply')]
    [string] $Stage = 'prepare-plan',
    [switch] $ConfigureOnly
)

$ErrorActionPreference = 'Stop'

function Assert-CreateOnlyPreparation {
    param([hashtable] $Plan)

    foreach ($change in $Plan.resource_changes) {
        if ($change.mode -ne 'managed' -or
            ($change.change.actions -join ',') -eq 'no-op') {
            continue
        }
        if (-not $change.address.StartsWith('module.cuny_prepare.')) {
            throw "Preparation would change an existing resource: $($change.address)"
        }
        if (($change.change.actions -join ',') -ne 'create') {
            throw "Preparation is create-only: $($change.address)"
        }
    }
}

function Get-CunyArchitecture {
    $scratch = Join-Path $env:MIGRATION_DIRECTORY 'decode'
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $path = (Join-Path $PWD 'lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml') |
        ConvertTo-Json -Compress
    $encoded = "jsonencode(yamldecode(file($path)))" |
        & terraform "-chdir=$scratch" console -no-color
    if ($LASTEXITCODE -ne 0) { throw 'Cannot decode the target architecture.' }
    return ($encoded | ConvertFrom-Json | ConvertFrom-Json -AsHashtable)
}

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $env:MIGRATION_DIRECTORY) { throw 'MIGRATION_DIRECTORY is required.' }

if ($ConfigureOnly) {
    $architecture = Get-CunyArchitecture
    $architecture.name = 'cuny_prepare'
    $architecture.management_groups = @($architecture.management_groups |
        Where-Object { $_.id -in @('cuny', 'bmcc', 'brooklyn', 'queens') })
    if ($architecture.management_groups.Count -ne 4) {
        throw 'Preparation requires exactly cuny and the three confirmed colleges.'
    }
    $architecture | ConvertTo-Json -Depth 100 |
        Set-Content 'lib/architecture_definitions/cuny_prepare.alz_architecture_definition.json'

    # Keep the existing deployment unchanged while a separate module creates destinations.
    $baseline = 'fc23b9daca8cda8c9bdadaeb05f84000a769317a'
    foreach ($file in @(
        'lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml',
        'platform-landing-zone.auto.tfvars',
        'terraform.tfvars.json'
    )) {
        $content = & git show "${baseline}:$file"
        if ($LASTEXITCODE -ne 0) { throw "Cannot restore the migration baseline: $file" }
        $content | Set-Content $file
    }
    @'
module "cuny_prepare" {
  source  = "Azure/avm-ptn-alz/azurerm"
  version = "0.21.0"

  architecture_name     = "cuny_prepare"
  parent_resource_id    = module.config.outputs.management_group_settings.parent_resource_id
  location              = module.config.outputs.management_group_settings.location
  policy_default_values = local.policy_default_values
  policy_assignments_to_modify = {
    cuny     = local.policy_assignments_to_modify.alz
    bmcc     = local.policy_assignments_to_modify.landingzones
    brooklyn = local.policy_assignments_to_modify.landingzones
    queens   = local.policy_assignments_to_modify.landingzones
  }
  enable_telemetry                     = var.enable_telemetry
  policy_assignments_dependencies      = local.management_group_dependencies
  policy_role_assignments_dependencies = local.management_group_dependencies
}
'@ | Set-Content 'cuny_prepare.tf'
    return
}

$planPath = Join-Path $env:MIGRATION_DIRECTORY 'prepare.tfplan'
& terraform plan -input=false -no-color -lock-timeout=5m "-out=$planPath"
if ($LASTEXITCODE -ne 0) { throw 'Terraform preparation plan failed.' }
$plan = (& terraform show -json $planPath) | ConvertFrom-Json -AsHashtable -Depth 100
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the preparation plan.' }
Assert-CreateOnlyPreparation $plan

$expected = @{
    management_groups_level_1 = 3
    policy_assignments = 173
    policy_definitions = 149
    policy_set_definitions = 44
    role_definitions = 5
}
foreach ($name in $expected.Keys) {
    $actual = @($plan.resource_changes | Where-Object {
        $_.mode -eq 'managed' -and $_.module_address -eq 'module.cuny_prepare' -and
        $_.name -eq $name -and ($_.change.actions -join ',') -eq 'create'
    }).Count
    if ($actual -ne $expected[$name]) {
        throw "Unexpected preparation count for ${name}: $actual, expected $($expected[$name])."
    }
}
Write-Host "Verified create-only preparation counts: $($expected | ConvertTo-Json -Compress)"
if ($Stage -eq 'prepare-apply') {
    & terraform apply -input=false -no-color $planPath
    if ($LASTEXITCODE -ne 0) { throw 'Terraform preparation apply failed.' }
}
