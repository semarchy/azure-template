#!/bin/bash -e

# Help menu
print_help() {
cat <<-HELP
Usage: $0 [--resource-group=resource-group-name] [--xdm-version=version] [--admin-password=admin-password]
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
    --xdm-version=*)
        version="${1#*=}"
        ;;
    --admin-password=*)
        serverPassword="${1#*=}"
        ;;
    --help) print_help;;
    *)
      printf "************************************************************\n"
      printf "* Error: Invalid argument, run --help for argument list.   *\n"
      printf "************************************************************\n"
      exit 1
  esac
  shift
done

if [[ -z $version || -z $resourceGroupName ]]
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

export AZURE_HTTP_USER_AGENT='pid-b196565f-e39e-5007-9fb7-63dd46818292'

versionDigits=(${version//./ })

imagePublisher=semarchy
imageOffer=xdm-solution-vm

if (( ${#versionDigits[@]} == 3 )); then
    if [[ ${versionDigits[2]} = "preview" ]]; then
        planName=${versionDigits[0]}'_'${versionDigits[1]}'_preview'
        imageVersion=latest
    else
        planName=${versionDigits[0]}'_'${versionDigits[1]}
        imageVersion=${versionDigits[0]}'.'${versionDigits[1]}'.'${versionDigits[2]}
    fi
else
    planName=${versionDigits[0]}'_'${versionDigits[1]}
    imageVersion=latest
fi

echo " -- Plan $planName and version $imageVersion pre-upgrade checks."

# check we can find scaleSet and active vm
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

# check password is ok
appGwName=$(az resource list --tag xdm-resource-type=app-gw --query "[?resourceGroup=='$resourceGroupName'].name" -o tsv)
if [[ -z $appGwName ]]
then
    echo " !! Application gateway not found in $resourceGroupName."
    exit 1;
fi
echo " -- Application gateway found ($appGwName)."

fPort=$(az network application-gateway frontend-port show --gateway-name $appGwName --resource-group $resourceGroupName --name appGwFrontendPortActive | jq '.port')
fProtocol=$(az network application-gateway http-listener show --gateway-name $appGwName --resource-group $resourceGroupName --name appGwHttpListenerActive | jq -r '.protocol' | tr '[:upper:]' '[:lower:]')

publicIpName=$(az resource list --tag xdm-resource-type=public-ip --query "[?resourceGroup=='$resourceGroupName'].name" -o tsv)
if [[ -z $publicIpName ]]
then
    echo " !! Public IP not found in $resourceGroupName."
    exit 1; 
fi
fAddress=$(az network public-ip show --name $publicIpName --resource-group $resourceGroupName | jq -r '.ipAddress')
echo " --> Public IP found. Checking $fProtocol://$fAddress:$fPort/ ..."

httpStatus=$(curl --insecure -s -o /dev/null -w "%{http_code}" -u "$serverUser:$serverPassword" $fProtocol://$fAddress:$fPort/manager/text/list)

if (( $httpStatus != 200 )); then
    echo " !! Invalid admin credentials (response status: $httpStatus)."
    exit 1;
else 
    echo " -- Admin credentials are valid."
fi

echo " --> Upgrade can proceed. Moving current xDM instance to new version..."
az vm image terms accept --publisher $imagePublisher --offer $imageOffer --plan $planName

echo " --> Updating scale set image..."
az vmss update --name $scaleSetName --resource-group $resourceGroupName --set virtualMachineProfile.storageProfile.imageReference.version=$imageVersion
echo " -- Scale set updated."

echo " --> Deleting obsolete active VM ($vmActiveId)..."
az vm delete --ids $vmActiveId --yes
az resource wait --deleted --ids $vmActiveId
echo " -- Obsolete active VM deleted."

echo " --> Re-creating Active VM..."
vmName=$(echo $currentVmProps | jq -r '.name')

echo "########## Running script ##########"

printf "az vm create --resource-group $resourceGroupName \\
    --name $vmName \\
    --admin-password <password> \\
    --admin-username $serverUser \\
    --authentication-type password \\
    --computer-name $(echo $currentVmProps | jq -r '.osProfile.computerName') \\
    --image $imagePublisher:$imageOffer:$planName:$imageVersion \\
    --plan-name $planName \\
    --plan-product $imageOffer \\
    --plan-publisher $imagePublisher \\
    --location $(echo $currentVmProps | jq -r '.location') \\
    --nics $(echo $currentVmProps | jq -r '.networkProfile.networkInterfaces[0].id') \\
    --os-disk-caching $(echo $currentVmProps | jq -r '.storageProfile.osDisk.caching') \\
    --os-disk-size-gb $(echo $currentVmProps | jq -r '.storageProfile.osDisk.diskSizeGb') \\
    --size $(echo $currentVmProps | jq -r '.hardwareProfile.vmSize') \\
    --tags xdm-resource-type=vm-active\n"

echo "####################################"

az vm create --resource-group $resourceGroupName \
    --name $vmName \
    --admin-password "$serverPassword" \
    --admin-username "$serverUser" \
    --authentication-type password \
    --computer-name $(echo $currentVmProps | jq -r '.osProfile.computerName') \
    --image $imagePublisher:$imageOffer:$planName:$imageVersion \
    --plan-name $planName \
    --plan-product $imageOffer \
    --plan-publisher $imagePublisher \
    --location $(echo $currentVmProps | jq -r '.location') \
    --nics $(echo $currentVmProps | jq -r '.networkProfile.networkInterfaces[0].id') \
    --os-disk-caching $(echo $currentVmProps | jq -r '.storageProfile.osDisk.caching') \
    --os-disk-size-gb $(echo $currentVmProps | jq -r '.storageProfile.osDisk.diskSizeGb') \
    --size $(echo $currentVmProps | jq -r '.hardwareProfile.vmSize') \
    --tags xdm-resource-type=vm-active

echo " -- Active VM created."

echo " --> Running upgrade script..."

storageKey=$(az storage account keys list --account-name $storageName --resource-group $resourceGroupName | jq -r '.[0].value')

echo "########## Running script ##########"

printf "az vm extension set \\
  --resource-group $resourceGroupName \\
  --vm-name $vmName \\
  --name customScript \\
  --publisher Microsoft.Azure.Extensions \\
  --protected-settings {\"commandToExecute\": \"/usr/local/xdm/bin/upgrade-instance-ubuntu.sh --storage-name=\"$storageName\" --storage-key=<storage key> --storage-folder=xdm-assets --server-user=\"$serverUser\" --server-password=<server password>\"}\n"

echo "####################################"

az vm extension set \
  --resource-group $resourceGroupName \
  --vm-name $vmName \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/upgrade-instance-ubuntu.sh --storage-name=\"'$storageName'\" --storage-key=\"'$storageKey'\" --storage-folder=xdm-assets --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\""}'

echo " -- Upgrade script completed."

echo " -- Instance upgraded successfully."