#!/bin/bash
rg=mf-hybrid-conn
loc=uksouth
vnet=mf-hybrid-conn-vnet
vmsubnet=vms
bastionsubnet=AzureBastionSubnet
bastion_public_ip_name=mf-hybrid-conn-bastion-public-ip
vnet_ip=10.0.0.0/16
vms_ip=10.0.0
bastion_ip=10.0.1
vm_ip_mask=24
bastion_ip_mask=24
resource_prefix="my-hy"
api_vm_prefix="$resource_prefix-api"
hcm_vm_prefix="$resource_prefix-hcm"
api_vm_count=2
hcm_vm_count=2
uid=AzureAdmin
read -p 'Administrator Password for VM: ' pwd
storagename=mfhybridscripts
container_name=scripts
app_plan_name="$resource_prefix-app-plan"
function_name="$resource_prefix-func"
servicebus_name="myhyconnsb"
hc_prefix="mfapivmhc"
dns_zone="$resource_prefix.lan"
dns_link_name="$resource_prefix-link"
hc_connection_strings=""

#create the resource group
az group create --location $loc --name $rg

#create the vnet
az network vnet create \
  --name $vnet \
  --resource-group $rg \
  --location $loc \
  --address-prefix $vnet_ip

#add the vm subnet
az network vnet subnet create \
    --address-prefixes "$vms_ip.0/$vm_ip_mask" \
    --name $vmsubnet \
    --resource-group $rg \
    --vnet-name $vnet

#add the bastion subnet
az network vnet subnet create \
    --address-prefixes "$bastion_ip.0/$bastion_ip_mask" \
    --name $bastionsubnet \
    --resource-group $rg \
    --vnet-name $vnet

#create a public ip for the Bastion
az network public-ip create \
    -n $bastion_public_ip_name \
    -g $rg \
    --sku Standard

#Create the private dns zone
az network private-dns zone create -g $rg -n $dns_zone

az network private-dns link vnet create \
    --name $dns_link_name \
    --registration-enabled true \
    --resource-group $rg \
    --virtual-network $vnet \
    --zone-name $dns_zone

#TODO: Create the Bastion

#create a storage account
az storage account create \
    -g $rg -n $storagename

#get the keys
storagekey=$(az storage account keys list -g $rg -n $storagename --query "[?keyName=='key1'].value" --output tsv)

#create a blob container
az storage container create \
    --name $container_name \
    --public-access off \
    --account-name $storagename \
    --account-key $storagekey

#upload the files
az storage blob upload \
    -f ./addjson.ps1   \
    -c $container_name \
    -n "addjson.ps1" \
    --account-name $storagename \
    --account-key $storagekey

az storage blob upload \
    -f ./HybridConnectionManager.msi   \
    -c $container_name \
    -n "HybridConnectionManager.msi" \
    --account-name $storagename \
    --account-key $storagekey

az storage blob upload \
    -f ./updateHCM.ps1   \
    -c $container_name \
    -n "updateHCM.ps1" \
    --account-name $storagename \
    --account-key $storagekey

#get the sas token for a blob
scriptscontainersas=$(az storage container generate-sas \
    -n $container_name \
    --account-name $storagename \
    --account-key $storagekey \
    --expiry 2020-02-28T00:00:00Z \
    --permissions r) 

escapedsas=$(echo $scriptscontainersas | tr -d '"')
containeruri="https://$storagename.blob.core.windows.net/$container_name"
addjsonuri="$containeruri/addjson.ps1?$escapedsas"
echo $addjsonuri
hcminstalluri="$containeruri/HybridConnectionManager.msi?$escapedsas"
echo $hcminstalluri
updateHCMUri="$containeruri/updateHCM.ps1?$escapedsas"
echo $updateHCMUri

#Create a relay namespace
az relay namespace create --name $servicebus_name --resource-group $rg

#Create an app service plan

az appservice plan create -n $app_plan_name -g $rg --sku S1

#create the function

az functionapp create -g $rg -n $function_name -p $app_plan_name -s $storagename --runtime dotnet

#add the api vms
start_range=5
end_range=$(($api_vm_count + $start_range - 1))
for i in $( seq $start_range $end_range)
do

    vmname="$api_vm_prefix-$i"
    #create the vm
    az vm create \
        --name "$vmname" \
        --resource-group $rg \
        --private-ip-address "$vms_ip.$i" \
        --vnet-name $vnet \
        --subnet $vmsubnet \
        --image Win2019Datacenter \
        --admin-username $uid \
        --admin-password $pwd \
        --public-ip-address "" \
        --os-disk-name "$api_vm_prefix-$i-os-disk"
    
    # Open port 80 to allow web traffic to host.
    az vm open-port --port 80 --resource-group $rg --name $vmname --priority 100 
    # Open port 443 to allow web traffic to host.
    az vm open-port --port 443 --resource-group $rg --name $vmname --priority 200

    #install IIS on the machine
    # Use CustomScript extension to install IIS.
    az vm extension set \
        --publisher Microsoft.Compute \
        --version 1.8 \
        --name CustomScriptExtension \
        --vm-name $vmname  \
        --resource-group $rg \
        --settings '{"commandToExecute":"powershell.exe Install-WindowsFeature -Name Web-Server"}'

    prefix='{"fileUris": ["'
    suffix='"], "commandToExecute": "powershell.exe -ExecutionPolicy Unrestricted -File addjson.ps1"}'
    addjsonsettings="$prefix$addjsonuri$suffix"
    # Use CustomScript extension to create a file at the wwwroor.
    az vm extension set \
        --publisher Microsoft.Compute \
        --version 1.8 \
        --name CustomScriptExtension \
        --vm-name $vmname  \
        --resource-group $rg \
        --settings "$addjsonsettings"

    

    # add a hybrid connection to the relay
    hc_name="http$hc_prefix$i"
    machine_name="$vmname.$dns_zone"
    relay_metadata="[{\"key\":\"endpoint\",\"value\":\"$machine_name:80\"}]"
    az relay hyco create \
        --resource-group $rg \
        --namespace-name $servicebus_name \
        --name $hc_name \
        --user-metadata $relay_metadata

    #Create the defaultListener auth rule
    az relay hyco authorization-rule create \
        --name defaultListener \
        --resource-group $rg \
        --namespace-name $servicebus_name \
        --hybrid-connection-name $hc_name \
        --rights Listen

    primaryConnKey=$(az relay hyco authorization-rule keys list \
    --name defaultListener \
    --resource-group $rg \
    --namespace-name $servicebus_name \
    --hybrid-connection-name $hc_name \
    --query "primaryKey" --output tsv)

    hc_conn_string="Endpoint=sb://$servicebus_name.servicebus.windows.net/$hc_name;SharedAccessKeyName=defaultListener;SharedAccessKey=$primaryConnKey"
    hc_connection_strings="$hc_connection_strings|$hc_conn_string"

    az functionapp hybrid-connection add \
        --hybrid-connection $hc_name \
        --name $function_name \
        --namespace $servicebus_name \
        --resource-group $rg 

    # add a hybrid connection to the relay (HTTPS)
    hc_name="https$hc_prefix$i"

    machine_name="$vmname.$dns_zone"
    relay_metadata="[{\"key\":\"endpoint\",\"value\":\"$machine_name:443\"}]"

    #Create the hybrid connection with the defaultSender auth rule
    az relay hyco create \
        --resource-group $rg \
        --namespace-name $servicebus_name \
        --name $hc_name \
        --user-metadata $relay_metadata

    #Create the defaultListener auth rule
    az relay hyco authorization-rule create \
        --name defaultListener \
        --resource-group $rg \
        --namespace-name $servicebus_name \
        --hybrid-connection-name $hc_name \
        --rights Listen

    primaryConnKey=$(az relay hyco authorization-rule keys list \
    --name defaultListener \
    --resource-group $rg \
    --namespace-name $servicebus_name \
    --hybrid-connection-name $hc_name \
    --query "primaryKey" --output tsv)

    hc_conn_string="Endpoint=sb://$servicebus_name.servicebus.windows.net/$hc_name;SharedAccessKeyName=defaultListener;SharedAccessKey=$primaryConnKey"
    hc_connection_strings="$hc_connection_strings|$hc_conn_string"

    az functionapp hybrid-connection add \
        --hybrid-connection $hc_name \
        --name $function_name \
        --namespace $servicebus_name \
        --resource-group $rg 
    
done



#add the hcm vms
start_range=$(($endrange + 10))
end_range=$(($hcm_vm_count + $start_range - 1))
for i in $( seq $start_range $end_range)
do

    vmname="$hcm_vm_prefix-$i"
    #create the vm
    az vm create \
        --name "$vmname" \
        --resource-group $rg \
        --private-ip-address "$vms_ip.$i" \
        --vnet-name $vnet \
        --subnet $vmsubnet \
        --image Win2019Datacenter \
        --admin-username $uid \
        --admin-password $pwd \
        --public-ip-address "" \
        --os-disk-name "$hcm_vm_prefix-$i-os-disk"
    
    # Open port 80 to allow web traffic to host.
    az vm open-port --port 80 --resource-group $rg --name $vmname --priority 100 
    # Open port 443 to allow web traffic to host.
    az vm open-port --port 443 --resource-group $rg --name $vmname --priority 200

    prefix='{"fileUris": ["'
suffix='"], "commandToExecute": "start /wait msiexec /package HybridConnectionManager.msi /quiet"}'
hcminstallsettings="$prefix$hcminstalluri$suffix"
echo $hcminstallsettings

    # Use CustomScript extension to install the hybrid connection manager
    az vm extension set \
        --publisher Microsoft.Compute \
        --version 1.8 \
        --name CustomScriptExtension \
        --vm-name $vmname  \
        --resource-group $rg \
        --settings "$hcminstallsettings"

    prefix='{"fileUris": ["'
    suffix='"], "commandToExecute": "powershell.exe  -ExecutionPolicy Unrestricted -File updateHCM.ps1 \"'
    suffix2='\" "}'
    updatehcmsettings="$prefix$updateHCMUri$suffix$hc_connection_strings$suffix2"
    echo $updatehcmsettings

    #Update HCM Listener config to point to the configured endpoints
    az vm extension set \
        --publisher Microsoft.Compute \
        --version 1.8 \
        --name CustomScriptExtension \
        --vm-name $vmname  \
        --resource-group $rg \
        --settings "$updatehcmsettings"
done





