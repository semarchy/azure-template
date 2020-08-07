#!/bin/bash -e

# Help menu
print_help() {
cat <<-HELP
Usage: $0 [--resource-group=resource-group-name] [--admin-password=admin-password]
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
    echo -n Admin Password: 
    read -s serverPassword
    echo
fi

if ! $(az group exists --name $resourceGroupName)
then 
	echo " !! resource group $resourceGroupName not found."
    exit 1;
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
vmName=$(echo $currentVmProps | jq -r '.name')

echo " --> Restarting active VM..."
az vm extension set \
  --resource-group $resourceGroupName \
  --vm-name $vmName \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --force-update \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/deploy-webapp-ubuntu.sh --xdm-package=active --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\""}'
echo " -- Active VM restarted."

echo " --> Restarting scale set..."
az vmss reimage --name $scaleSetName --resource-group $resourceGroupName
echo " -- Scale set restarted."

echo " -- Instance restarted successfully."

