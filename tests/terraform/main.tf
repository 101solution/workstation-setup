locals {
  name = "${var.name_prefix}-${var.os == "win11" ? "client" : "server"}"
  images = {
    server2025 = {
      publisher = "MicrosoftWindowsServer"
      offer     = "WindowsServer"
      sku       = "2025-datacenter-g2"
    }
    win11 = {
      publisher = "MicrosoftWindowsDesktop"
      offer     = "windows-11"
      sku       = "win11-24h2-ent"
    }
  }
  tags = {
    purpose = "workstation-setup-validation"
  }
}

resource "azurerm_resource_group" "test" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "test" {
  name                = "${local.name}-vnet"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  address_space       = ["10.42.0.0/24"]
  tags                = local.tags
}

resource "azurerm_subnet" "test" {
  name                 = "test"
  resource_group_name  = azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.test.name
  address_prefixes     = ["10.42.0.0/26"]
}

resource "azurerm_network_security_group" "test" {
  name                = "${local.name}-nsg"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  tags                = local.tags

  security_rule {
    name                       = "RDP-from-test-operator"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.rdp_source_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "test" {
  name                = "${local.name}-ip"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "test" {
  name                = "${local.name}-nic"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.test.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.test.id
  }
}

resource "azurerm_network_interface_security_group_association" "test" {
  network_interface_id      = azurerm_network_interface.test.id
  network_security_group_id = azurerm_network_security_group.test.id
}

resource "azurerm_windows_virtual_machine" "test" {
  name                  = local.name
  computer_name         = "${var.name_prefix}-${var.os == "win11" ? "cli" : "srv"}"
  resource_group_name   = azurerm_resource_group.test.name
  location              = azurerm_resource_group.test.location
  size                  = var.vm_size
  admin_username        = var.os == "win11" ? "azureadmin" : "test.user"
  admin_password        = var.admin_password
  license_type          = var.os == "win11" ? "Windows_Client" : null
  network_interface_ids = [azurerm_network_interface.test.id]
  tags                  = local.tags

  os_disk {
    name                 = "${local.name}-os"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = local.images[var.os].publisher
    offer     = local.images[var.os].offer
    sku       = local.images[var.os].sku
    version   = var.image_version
  }

  depends_on = [azurerm_network_interface_security_group_association.test]
}

# Wait for VM provisioning to finish before locating its OS disk. No setup extension
# or provisioner runs on this VM, so the snapshot contains the fresh image only.
data "azurerm_managed_disk" "os" {
  name                = azurerm_windows_virtual_machine.test.os_disk[0].name
  resource_group_name = azurerm_resource_group.test.name
  depends_on          = [azurerm_windows_virtual_machine.test]
}

resource "azurerm_snapshot" "fresh" {
  name                = "${local.name}-fresh"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  create_option       = "Copy"
  source_resource_id  = data.azurerm_managed_disk.os.id
  incremental_enabled = true
  tags                = local.tags

  lifecycle {
    replace_triggered_by = [azurerm_windows_virtual_machine.test.id]
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "test" {
  virtual_machine_id    = azurerm_windows_virtual_machine.test.id
  location              = azurerm_resource_group.test.location
  enabled               = true
  daily_recurrence_time = "2200"
  timezone              = "W. Australia Standard Time"
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
