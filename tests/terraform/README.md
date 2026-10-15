# Disposable Azure validation VM

This Terraform configuration creates one Windows VM and copies its OS disk into a
fresh incremental snapshot as soon as Azure reports VM provisioning complete.
There are no setup scripts, extensions, or autologon configuration. Wait for the
whole apply to succeed, including the snapshot, before connecting or installing
anything. The running-disk snapshot is crash-consistent, not an application backup.

Defaults are Windows Server 2025 in Australia East, `Standard_D2s_v5` (2 vCPU,
8 GB RAM), a 128 GB Standard HDD OS disk, and a Standard incremental snapshot.
Dsv5 supports the nested virtualization required for WSL/Hyper-V validation.
The smaller size costs less than the previous D4s_v5 rig; use `Standard_D4s_v5`
if large role installations need more memory or CPU. Burstable B-series are not
the default because the Docker/WSL tests require nested virtualization. Prices,
quota, SKU capacity, and image availability must be checked in the target subscription.
Windows Server uses pay-as-you-go licensing; the Windows 11 option requires an
eligible Windows client license and sets `Windows_Client` accordingly.

Only one VM is created per deployment. Test the two supported operating systems
sequentially to minimize concurrent cost, or use separate working directories and
distinct `name_prefix` values for independent rigs and Terraform states.

## Create

Requires Terraform >= 1.5, Azure CLI authentication, and permissions to manage the
resources. The subscription must already have the `Microsoft.Compute`,
`Microsoft.Network`, and `Microsoft.DevTestLab` providers registered; Terraform
does not automatically register providers across this shared subscription.

From this directory in PowerShell:

```powershell
az login
$testSubscriptionId = az account show --subscription <your-test-subscription> --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $testSubscriptionId) { throw 'Could not resolve <your-test-subscription>.' }
$env:TF_VAR_subscription_id = $testSubscriptionId

Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set rdp_source_cidr to your own public IPv4 address
# followed by /32. Select server2025 or win11.
$testCredential = Get-Credential -UserName test.user -Message 'Choose a fresh Azure VM password (16+ characters)'
$env:TF_VAR_admin_password = $testCredential.GetNetworkCredential().Password

terraform init
terraform validate
terraform plan -out=create.tfplan
terraform apply create.tfplan
terraform output
```

The Server administrator is `test.user` to exercise installers with dotted profile
names; Windows 11 uses `azureadmin`. The password must meet Azure complexity rules.
RDP is restricted to the required operator IPv4 `/32`. Docker ports are not opened
through the NSG; validate the daemons inside the VM.

Terraform state and saved plans contain the administrator password even though it
is marked sensitive. State, plans, provider downloads, and real variable files are
gitignored. Keep them private and retain state until the rig is destroyed. Commit
the generated `.terraform.lock.hcl` after a successful init to pin the provider.

For repeatable image selection, resolve the image before applying and set its
version in `terraform.tfvars`:

```powershell
az vm image show --subscription $testSubscriptionId --location australiaeast --urn MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest --query '{version:name,sizeGiB:osDiskImage.sizeInGb}' -o json
# Windows 11 alternative:
az vm image show --subscription $testSubscriptionId --location australiaeast --urn MicrosoftWindowsDesktop:windows-11:win11-24h2-ent:latest --query '{version:name,sizeGiB:osDiskImage.sizeInGb}' -o json
```

The selected image must fit the 128 GB disk. The snapshot is recreated when Terraform
replaces the VM; ordinary applies do not overwrite the fresh snapshot with a used
disk. Changing operating systems replaces the rig and its snapshot, so finish
validation and retain any needed evidence before making that change.

## Restore point

`terraform output -raw fresh_snapshot_id` identifies the restore point. Azure restores
a disk snapshot by creating a **new managed disk** from it; the snapshot cannot be
attached directly. Deallocate the VM before swapping its OS disk in the Azure portal.
The restored disk is specialized and retains the original administrator credentials.
VM network configuration remains on the VM, outside the disk snapshot.

An OS disk swap outside Terraform creates drift: this configuration manages the
original disk and image-created VM. Do not apply it over a manually restored VM;
use the restored VM for that validation run, then clean up the extra restore disk
and destroy/recreate the rig for the next Terraform-managed deployment. Terraform
does not manage or delete extra disks created manually during restore.

## Keep costs down and clean up

The nightly Azure shutdown schedule stops/deallocates the VM at 22:00 Perth time.
Deallocate sooner when a run ends; shutting down inside Windows alone can leave
compute allocated. Disks, snapshots, and the static public IP continue to incur
charges while the VM is deallocated.

```powershell
$testResourceGroup = terraform output -raw resource_group_name
$testVmName = terraform output -raw vm_name
az vm deallocate --subscription $testSubscriptionId --resource-group $testResourceGroup --name $testVmName

# Remove the VM, original disk, fresh snapshot, public IP, network, and test group:
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
Remove-Item Env:TF_VAR_admin_password
```

Destroy removes the restore point too. Retain the private Terraform state and
password until cleanup finishes. No Azure resources are created by `init`,
`validate`, or `plan`.
