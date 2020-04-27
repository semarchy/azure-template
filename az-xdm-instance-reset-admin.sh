#!/bin/bash -e

# Help menu
print_help() {
cat <<-HELP
Usage: $0 [--resource-group=resource-group-name] [--admin-password=new-admin-password]
HELP
exit 1
}

serverPassword=$XDM_ADMIN_PASSWORD
resourceGroupName=$XDM_RESOURCE_GROUP
# Parse Command Line Arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resource-group=*)
        resourceGroupName="${1#*=}"
        ;;
    --admin-password=*)
        serverPassword="${1#*=}"
        ;;
    --help) print_help;;
    *)
      printf "***********************************************************\n"
      printf "* Error: Invalid argument, run --help for argument list  .*\n"
      printf "***********************************************************\n"
      exit 1
  esac
  shift
done

if [[ -z $resourceGroupName ]]
then
    print_help
fi

if [[ -z $serverPassword ]]
then
    # Read Password
    echo -n New Admin Password: 
    read -s serverPassword
    echo
fi

scaleSetName=$(az resource list --tag xdm-resource-type=ss-passive --query "[?resourceGroup=='$resourceGroupName'].name" -o tsv)
if [[ -z $scaleSetName ]]
then
    echo " !! Scale set not found in $resourceGroupName."
    exit 1;
fi
echo " -- Scale set found ($scaleSetName)."

vmActiveId=$(az resource list --tag xdm-resource-type=vm-active --query "[?resourceGroup=='$resourceGroupName'].id" -o tsv)
if [[ -z $vmActiveId ]]
then
    echo " !! Active VM not found in $resourceGroupName."
    exit 1;
fi
echo " -- Active VM found ($vmActiveId)."

# retrieve current vm properties
currentVmProps=$(az vm show --ids $vmActiveId)
serverUser=$(echo $currentVmProps | jq -r '.osProfile.adminUsername')

#check storage
storageName=$(az resource list --tag xdm-resource-type=storage --query "[?resourceGroup=='$resourceGroupName'].name" -o tsv)
if [[ -z $storageName ]]
then
    echo " !! Storage not found in $resourceGroupName."
    exit 1;
fi
echo " -- Storage found ($storageName)."

storageKey=$(az storage account keys list --account-name $storageName --resource-group $resourceGroupName | jq -r '.[0].value')

echo " --> Changing admin password on active VM..."
vmName=$(echo $currentVmProps | jq -r '.name')

az vm user update --resource-group $resourceGroupName \
  --name $vmName \
  --username $serverUser \
  --password $serverPassword

az vm extension set \
  --resource-group $resourceGroupName \
  --vm-name $vmName \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --force-update \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/update-admin-password-ubuntu.sh --server-user='$serverUser' --server-password='$serverPassword'"}'
echo " -- Active VM updated."

echo " --> Change admin password on scale set..."
az vmss update --name $scaleSetName --resource-group $resourceGroupName --set virtualMachineProfile.osProfile.adminPassword=$serverPassword
az vmss update --name $scaleSetName --resource-group $resourceGroupName --set upgradePolicy.mode=Manual
az vmss extension set \
  --resource-group $resourceGroupName \
  --vmss-name $scaleSetName \
  --name customScript \
  --extension-instance-name config-passives \
  --publisher Microsoft.Azure.Extensions \
  --no-auto-upgrade true \
  --protected-settings '{"commandToExecute": "bash /usr/local/xdm/bin/init-ss-ubuntu.sh --storage-name='$storageName' --storage-key='$storageKey' --storage-folder=xdm-assets --server-user='$serverUser' --server-password='$serverPassword'"}'
az vmss update --name $scaleSetName --resource-group $resourceGroupName --set upgradePolicy.mode=Automatic
echo " -- Scale set updated."

echo " -- Admin password changed."

