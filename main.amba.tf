locals {
  root_management_group_name = yamldecode(file("${path.root}/lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml")).management_groups[0].id

  # root_management_group_name = jsondecode(file("${path.root}/lib/architecture_definitions/alz_custom.alz_architecture_definition.json")).management_groups[0].id
}

module "amba" {
  source  = "Azure/avm-ptn-monitoring-amba-alz/azurerm"
  version = "0.4.0"
  providers = {
    azurerm = azurerm.management
  }
  location                            = var.starter_locations[0]
  root_management_group_name          = local.root_management_group_name
  resource_group_name                 = module.config.custom_replacements.amba_resource_group_name
  user_assigned_managed_identity_name = module.config.custom_replacements.amba_user_assigned_managed_identity_name
}