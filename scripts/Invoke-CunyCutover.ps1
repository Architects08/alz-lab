param(
    [ValidateSet('cutover-plan', 'cutover-apply')]
    [string] $CutoverStage = 'cutover-plan'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Invoke-CunyMigration.ps1"

function Invoke-TerraformChecked {
    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
    & terraform @Arguments | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Terraform failed: $($Arguments[0])" }
}

function Get-StateEntries {
    $state = (& terraform state pull) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read platform state.' }
    if ($state.lineage -ne '98ac4e86-d505-bd80-0fa1-eb2c88d11db0') {
        throw 'This is not the inventoried platform state.'
    }
    foreach ($resource in $state.resources) {
        if ($resource.mode -ne 'managed') { continue }
        foreach ($instance in $resource.instances) {
            $address = (@($resource.module, $resource.type, $resource.name) |
                Where-Object { $_ }) -join '.'
            if ($instance.ContainsKey('index_key')) {
                $address += "[$($instance.index_key | ConvertTo-Json -Compress)]"
            }
            @{
                Address = $address
                Module = $resource.module
                Type = $resource.type
                Name = $resource.name
                Key = $instance.index_key
                Attributes = $instance.attributes
            }
        }
    }
}

function Get-PolicyBody {
    param([hashtable] $Attributes)
    $body = $Attributes.body
    if ($body -is [hashtable] -and $body.ContainsKey('value')) { $body = $body.value }
    if ($body -is [string]) { $body = $body | ConvertFrom-Json -AsHashtable }
    return $body
}

function Get-AzureJson {
    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
    $json = & az @Arguments -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure inventory failed: $($Arguments -join ' ')" }
    return ($json | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Assert-CutoverPlan {
    param([hashtable] $Plan, [string[]] $Rebindings = @())

    foreach ($change in $Plan.resource_changes) {
        if ($change.mode -ne 'managed') { continue }
        $actions = $change.change.actions -join ','
        if ($actions -eq 'move') {
            if ($change.previous_address.StartsWith('module.cuny_prepare.') -and
                $change.address -eq $change.previous_address.Replace(
                    'module.cuny_prepare.', 'module.management_groups[0].'
                )) {
                continue
            }
            throw "Unexpected state ownership transfer: $($change.address)"
        }
        if ($change.address.StartsWith('module.cuny_prepare.') -and $actions -eq 'delete' -and
            $change.type -in @('terraform_data', 'time_sleep', 'modtm_telemetry', 'random_uuid')) {
            continue
        }
        if (-not $change.address.StartsWith('module.management_groups[0].')) {
            throw "Cutover would change an unrelated resource: $($change.address)"
        }
        if ($change.type -in @('terraform_data', 'time_sleep', 'modtm_telemetry', 'random_uuid')) {
            continue
        }
        if ($change.name.StartsWith('management_groups_level_')) {
            if ($actions -ne 'delete' -or
                $change.key -notin @('landingzones', 'corp', 'local', 'online')) {
                throw "A retained management group would change: $($change.address)"
            }
            continue
        }
        if ($change.type -eq 'azapi_resource_action') {
            if ($change.name -eq 'subscription_placement_delete' -and $actions -eq 'create') {
                continue
            }
            throw "Subscription placement would change during cutover: $($change.address)"
        }
        if ($change.type -ne 'azapi_resource') {
            throw "Unexpected cutover resource type: $($change.type)"
        }
        switch ($change.name) {
            { $_ -in @('policy_definitions', 'policy_set_definitions', 'role_definitions') } {
                if ($actions -ne 'delete' -or -not $change.key.StartsWith('alz/')) {
                    throw "Prepared root governance would change: $($change.address)"
                }
            }
            'policy_assignments' {
                $legacy = $change.key -match '^(alz|landingzones|corp|local|online)/'
                if (-not ($legacy -and $actions -eq 'delete') -and
                    $change.address -notin $Rebindings) {
                    throw "Unexpected policy assignment change: $($change.address)"
                }
            }
            'policy_role_assignments' { }
            default { throw "Unexpected cutover resource: $($change.address)" }
        }
    }
}

function Assert-CutoverInventory {
    param([array] $Entries)

    $prepared = @($Entries | Where-Object {
        $_.Name -eq 'policy_assignments' -and $_.Key -match '^(cuny|bmcc|brooklyn|queens)/'
    })
    if ($prepared.Count -ne 173) { throw 'Destination governance is not fully prepared.' }
    foreach ($group in @('corp', 'local', 'online')) {
        if ($group -notin $Entries.Key) { continue }
        $source = Get-AzureJson @('account', 'management-group', 'show', '--name', $group, '--expand')
        if (@($source.children | Where-Object { $_ }).Count -ne 0) {
            throw "$group is no longer empty; its contents require an explicit migration."
        }
    }
    $assignments = @($Entries | Where-Object { $_.Name -eq 'policy_assignments' })
    $oldRoleIds = @($Entries | Where-Object {
        $_.Name -eq 'role_definitions' -and $_.Key.StartsWith('alz/')
    } | ForEach-Object { ($_.Attributes.id -split '/')[-1] })
    $groups = @(@('alz', 'cuny') + @($Entries | Where-Object {
        $_.Name.StartsWith('management_groups_level_')
    } | ForEach-Object { $_.Key }) | Sort-Object -Unique)
    foreach ($group in $groups) {
        $scope = "/providers/Microsoft.Management/managementGroups/$group"
        $expected = @($assignments | Where-Object { $_.Key.StartsWith("$group/") } |
            ForEach-Object { ($_.Key -split '/', 2)[1] } | Sort-Object)
        $actual = @(Get-AzureJson @('policy', 'assignment', 'list', '--scope', $scope,
                '--query', '[].name') | Sort-Object)
        if (($expected -join "`n") -ne ($actual -join "`n")) {
            throw "Unmanaged or missing policy assignments were found at $group."
        }
        $exemptions = @(Get-AzureJson @('policy', 'exemption', 'list', '--scope', $scope))
        if ($exemptions.Count -gt 0) {
            throw "Policy exemptions at $group require explicit migration."
        }
        $roles = @(Get-AzureJson @('role', 'assignment', 'list', '--scope', $scope,
                '--query', '[].roleDefinitionId'))
        if (@($roles | Where-Object { ($_ -split '/')[-1] -in $oldRoleIds }).Count -gt 0) {
            throw "An old custom role has management-group consumers at $group."
        }
    }
}

function Invoke-Bridge {
    param([switch] $Apply)

    $entries = @(Get-StateEntries)
    $rebindings = @($entries | Where-Object {
        $_.Module -eq 'module.management_groups[0]' -and $_.Name -eq 'policy_assignments' -and
        $_.Key -match '^(platform|identity|sandbox|alz-lab-decommissioned)/' -and
        (Get-PolicyBody $_.Attributes).properties.policyDefinitionId.StartsWith(
            '/providers/Microsoft.Management/managementGroups/alz/'
        )
    } | ForEach-Object { $_.Address })
    $oldRoleIds = @($entries | Where-Object {
        $_.Name -eq 'role_definitions' -and $_.Key.StartsWith('alz/')
    } | ForEach-Object { ($_.Attributes.id -split '/')[-1] })
    $subscriptions = (Get-Content 'terraform.tfvars.json' -Raw | ConvertFrom-Json -AsHashtable).subscription_ids
    foreach ($subscription in @($subscriptions.management, $subscriptions.connectivity)) {
        $roles = @(Get-AzureJson @('role', 'assignment', 'list', '--all', '--subscription',
                $subscription, '--query', '[].roleDefinitionId'))
        if (@($roles | Where-Object { ($_ -split '/')[-1] -in $oldRoleIds }).Count -gt 0) {
            throw 'An old custom role has subscription/resource consumers; migrate those first.'
        }
        $exemptions = @(Get-AzureJson @('policy', 'exemption', 'list', '--scope', "/subscriptions/$subscription"))
        if (@($exemptions | Where-Object {
            $_.policyAssignmentId -like '/providers/Microsoft.Management/managementGroups/alz/*'
        }).Count -gt 0) {
            throw 'A subscription exemption references the old root and needs migration.'
        }
    }
    if ($Apply) {
        & az account management-group update --name alz --parent cuny --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw 'Cannot establish the common-ancestor governance bridge.' }
    }

    $moves = @()
    foreach ($entry in $entries | Where-Object {
        $_.Module -eq 'module.cuny_prepare' -and $_.Type -eq 'azapi_resource'
    }) {
        $destination = $entry.Address.Replace('module.cuny_prepare.', 'module.management_groups[0].')
        if ($destination -in $entries.Address) { throw "State destination already exists: $destination" }
        $moves += "moved {`n  from = $($entry.Address)`n  to = $destination`n}"
    }
    if (@($entries | Where-Object {
        $_.Module -eq 'module.cuny_prepare' -and
        $_.Type -notin @('azapi_resource', 'terraform_data', 'time_sleep', 'modtm_telemetry', 'random_uuid')
    }).Count -gt 0) {
        throw 'Unexpected resource type in the preparation module.'
    }
    ($moves -join "`n`n") | Set-Content 'cuny_state_moves.tf'

    $retained = @('platform', 'sandbox', 'alz-lab-decommissioned')
    $architecturePath = 'lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml'
    $originalArchitecture = [IO.File]::ReadAllBytes((Join-Path $PWD $architecturePath))
    $architecture = Get-CunyArchitecture
    foreach ($group in $architecture.management_groups) {
        if ($group.id -in $retained) { $group.exists = $true }
    }
    $architecture | ConvertTo-Json -Depth 100 | Set-Content $architecturePath
    @'
module "management_groups" {
  policy_assignments_dependencies      = []
  policy_role_assignments_dependencies = []
}
'@ | Set-Content 'cuny_cutover_override.tf'
    $entries = @(Get-StateEntries)
    $release = @($entries | Where-Object {
        $_.Module -eq 'module.management_groups[0]' -and
        (($_.Name.StartsWith('management_groups_level_') -and $_.Key -in $retained) -or
         ($_.Name -eq 'subscription_placement_delete' -and $_.Attributes.resource_id -like
          '/providers/Microsoft.Management/managementGroups/alz/subscriptions/*'))
    } | ForEach-Object { $_.Address })
    if ($release.Count -gt 0) {
        Invoke-TerraformChecked (@('state', 'rm', '-lock-timeout=5m') + $release)
    }
    $planPath = Join-Path $env:MIGRATION_DIRECTORY 'bridge.tfplan'
    $arguments = @('plan', '-json', '-input=false', '-parallelism=1', '-lock-timeout=5m',
        '-target=module.management_groups[0]', '-target=module.cuny_prepare', "-out=$planPath")
    if (-not $Apply) { $arguments += '-refresh=false' }
    foreach ($address in $rebindings) { $arguments += "-replace=$address" }
    $events = & terraform @arguments
    if ($LASTEXITCODE -ne 0) {
        $events | ForEach-Object { Write-Host $_ }
        throw 'Governance bridge plan failed.'
    }
    $plan = ConvertFrom-PlanEvents $events
    Assert-CutoverPlan $plan $rebindings
    Write-Host "Governance bridge plan passed. Policy assignment rebindings: $($rebindings.Count)."
    if (-not $Apply) { return }
    Invoke-TerraformChecked @('apply', '-input=false', '-no-color', $planPath)
    Remove-Item -LiteralPath 'cuny_state_moves.tf'
    [IO.File]::WriteAllBytes((Join-Path $PWD $architecturePath), $originalArchitecture)

    foreach ($group in $retained) {
        & az account management-group update --name $group --parent cuny --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw "Cannot move existing management group $group." }
        $address = 'module.management_groups[0].azapi_resource.management_groups_level_1[' +
            ($group | ConvertTo-Json -Compress) + ']'
        $id = "/providers/Microsoft.Management/managementGroups/${group}?api-version=2023-04-01"
        if ($address -notin @(Get-StateEntries).Address) {
            Invoke-TerraformChecked @('import', '-input=false', '-lock-timeout=5m', $address, $id)
        }
    }
    $finalPath = Join-Path $env:MIGRATION_DIRECTORY 'cutover-final.tfplan'
    $events = & terraform plan -json -input=false -parallelism=1 `
        '-target=module.management_groups[0]' "-out=$finalPath"
    if ($LASTEXITCODE -ne 0) { throw 'Post-import cutover plan failed.' }
    $final = ConvertFrom-PlanEvents $events
    Assert-CutoverPlan $final @()
    Invoke-TerraformChecked @('apply', '-input=false', '-no-color', $finalPath)
    Write-Host 'Retained groups moved in place. Bootstrap ownership reconciliation and legacy root retirement remain.'
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $env:MIGRATION_DIRECTORY) { throw 'MIGRATION_DIRECTORY is required.' }

$entries = @(Get-StateEntries)
Assert-CutoverInventory $entries
if ($CutoverStage -eq 'cutover-plan') {
    $preview = Join-Path $env:MIGRATION_DIRECTORY 'cutover-preview'
    $archive = Join-Path $env:MIGRATION_DIRECTORY 'cutover-source.zip'
    & git archive --format=zip "--output=$archive" HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create an isolated cutover preview.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $preview
    $configuration = Join-Path $preview 'terraform.tf'
    $content = Get-Content $configuration -Raw
    $pattern = 'backend\s+"azurerm"\s*\{\s*\}'
    if ([regex]::Matches($content, $pattern).Count -ne 1) {
        throw 'Expected exactly one empty azurerm backend declaration.'
    }
    [regex]::Replace($content, $pattern, 'backend "local" {}') | Set-Content $configuration
    Push-Location $preview
    try {
        Invoke-TerraformChecked @('init', '-input=false', '-no-color')
        Copy-Item "$env:MIGRATION_DIRECTORY/platform.tfstate" 'terraform.tfstate'
        Invoke-Bridge
    } finally {
        Pop-Location
    }
} else {
    Invoke-Bridge -Apply
}
