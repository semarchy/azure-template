#!/bin/bash -e

# Help menu
print_help() {
cat <<-HELP
Usage: $0 <--origin-resource-group=origin-resource-group-name> <--destination-resource-group=destination-resource-group-name> <--instance-name=instance-name> [--admin-password=admin-password] [--db-server-password=db-server-password]
HELP
exit 1
}

originResourceGroupName=$XDM_ORIGIN_RESOURCE_GROUP
destinationResourceGroupName=$XDM_DESTINATION_RESOURCE_GROUP
instanceName=$XDM_INSTANCE_NAME
serverPassword=$XDM_ADMIN_PASSWORD
databaseServerPassword=$XDM_DB_SERVER_PASSWORD

# Parse Command Line Arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --origin-resource-group=*)
        originResourceGroupName="${1#*=}"
        ;;
    --destination-resource-group=*)
        destinationResourceGroupName="${1#*=}"
        ;;
    --instance-name=*)
        instanceName="${1#*=}"
        ;;
    --admin-password=*)
        serverPassword="${1#*=}"
        ;;
    --db-server-password=*)
        databaseServerPassword="${1#*=}"
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

if [[ -z $originResourceGroupName || -z $destinationResourceGroupName || -z $instanceName ]]
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

export AZURE_HTTP_USER_AGENT='pid-ee0cf0e2-6610-4481-9d19-e1db68621749-partnercenter'

uniqueString=$(LC_CTYPE=C tr -dc a-z0-9 </dev/urandom | head -c 13 ;)

if ! $(az group exists --name $originResourceGroupName)
then
	echo " !! resource group $originResourceGroupName not found."
  exit 1;
fi

# check we can find scaleSet and active vm
scaleSetName=$(az resource list --tag xdm-resource-type=ss-passive --query "[?resourceGroup=='$originResourceGroupName'].name" -o tsv)
currentSsProps=$(az vmss show --name $scaleSetName --resource-group $originResourceGroupName)
if [[ -z $scaleSetName ]]
then
    echo " !! Scale set not found in $originResourceGroupName."
    exit 1;
fi
echo " -- Scale set found ($scaleSetName)."

vmActiveId=$(az resource list --tag xdm-resource-type=vm-active --query "[?resourceGroup=='$originResourceGroupName'].id" -o tsv)
if [[ -z $vmActiveId ]]
then
    echo " !! Active VM not found in $originResourceGroupName."
    exit 1;
fi
echo " -- Active VM found ($vmActiveId)."

# retrieve current vm properties
currentVmProps=$(az vm show --ids $vmActiveId)
serverUser=$(echo $currentVmProps | jq -r '.osProfile.adminUsername')

#check storage
storageId=$(az resource list --tag xdm-resource-type=storage --query "[?resourceGroup=='$originResourceGroupName'].id" -o tsv)
storageName=$(az resource list --tag xdm-resource-type=storage --query "[?resourceGroup=='$originResourceGroupName'].name" -o tsv)
if [[ -z $storageId ]]
then
    echo " !! Storage not found in $originResourceGroupName."
    exit 1;
fi
echo " -- Storage found ($storageName)."

dbServerId=$(az resource list --tag xdm-resource-type=db-server --query "[?resourceGroup=='$originResourceGroupName'].id" -o tsv)
if [[ -z $dbServerId ]]
then
    echo " !! Database server not found in $originResourceGroupName."
    exit 1;
fi

# retrieve current db properties
currentDbServerProps=$(az resource show --ids $dbServerId)
dbType=$(echo $currentDbServerProps | jq -r '.tags."xdm-database-type"')
echo " -- $dbType database server found ($dbServerId)."

databaseAdminUser=$(echo $currentDbServerProps | jq -r '.properties.administratorLogin')
databaseServerId=$(echo $currentDbServerProps | jq -r '.id')
databaseServerName=$(echo $currentDbServerProps | jq -r '.name')
destinationDatabaseServerName=$instanceName-db-$uniqueString

zone=$(date +%z)
datetime=$(date +%Y-%m-%dT%H:%M:%S)
now=$(echo $datetime${zone:0:3}:${zone:3:2})

vmName=$(echo $currentVmProps | jq -r '.name')
echo " --> Checking admin credentials..."

echo "########## Running script ##########"

printf "az vm extension set --resource-group $originResourceGroupName \\
    --vm-name $vmName \\
    --name customScript \\
    --publisher Microsoft.Azure.Extensions \\
    --protected-settings '{\"commandToExecute\": \"/usr/local/xdm/bin/check-admin-credentials-ubuntu.sh --server-user=\"'$serverUser'\" --server-password=\"<password>\"\"}'\n"

echo "####################################"

az vm extension set --resource-group $originResourceGroupName \
  --vm-name $vmName \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/check-admin-credentials-ubuntu.sh --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\""}'

echo " --> Clone can proceed. Cloning current xDM instance to $destinationResourceGroupName..."

resourceGroupLocation=$(az group show --name $originResourceGroupName  | jq -r '.location')
destinationVnet=$instanceName-vnet
destinationSubnetGw=$instanceName-subnet-gw
destinationSubnetSs=$instanceName-subnet-ss
destinationIpA=$instanceName-ip-a
destinationIp=$instanceName-ip
destinationGw=$instanceName-gw
destinationGwBap=$instanceName-gwbap
destinationAGwBap=$instanceName-a-gwbap
destinationNsg=$instanceName-nsg
destinationNic=$instanceName-nic-a
destinationVm=$instanceName-vm-a
destinationSs=$instanceName-ss

if ! $(az group exists --name $destinationResourceGroupName); then
  echo " --> Resource group $destinationResourceGroupName not found. Creating a new resource group with name $destinationResourceGroupName...."

  echo "########## Running script ##########"

  printf "az group create --name $destinationResourceGroupName \\
      --location $resourceGroupLocation\n"

  echo "####################################"

  az group create --name $destinationResourceGroupName \
      --location $resourceGroupLocation
else
  echo " --> Resource group $destinationResourceGroupName already exists"
fi

echo " --> Creating storage account... "

echo "########## Running script ##########"

destStorageName=xdmidh${uniqueString}

printf "az storage account create --resource-group $destinationResourceGroupName \\
    --name ${destStorageName} \\
    --default-action Allow \\
    --sku Standard_LRS \\
    --tags xdm-resource-type=storage\n"

echo "####################################"

az storage account create --resource-group $destinationResourceGroupName \
    --name ${destStorageName} \
    --default-action Allow \
    --sku Standard_LRS \
    --tags xdm-resource-type=storage

az resource wait --exists --resource-group $destinationResourceGroupName --name ${destStorageName} --resource-type Microsoft.Storage/storageAccounts --interval 5

echo " -- Storage account created."

echo " --> Update existing storage account... "

echo "########## Running script ##########"

printf "az storage account update --resource-group $originResourceGroupName \\
    --name ${storageName} \\
    --default-action Allow\n"

echo "####################################"

az storage account update --resource-group $originResourceGroupName \
    --name ${storageName} \
    --default-action Allow

sleep 20

echo " -- Storage account updated."

#check storage
storageKey=$(az storage account keys list --account-name $storageName --resource-group $originResourceGroupName | jq -r '.[0].value')
destStorageId=$(az resource list --tag xdm-resource-type=storage --query "[?resourceGroup=='$destinationResourceGroupName'].id" -o tsv)
destStorageKey=$(az storage account keys list --account-name $destStorageName --resource-group $destinationResourceGroupName | jq -r '.[0].value')

if [[ -z $destStorageId ]]
then
    echo " !! Storage not found in $destinationResourceGroupName."
    exit 1;
fi
echo " -- Storage found ($destStorageName)."

echo " --> Copying storage account... "

echo "########## Running script ##########"

printf "az storage copy --account-key <storage-key> \\
    --account-name $destStorageName \\
    --source-account-key <storage-key> \\
    --source-account-name $storageName \\
    --source-share xdm-assets \\
    --destination-share xdm-assets \\
    --recursive\n"

echo "####################################"

az storage copy --account-key $destStorageKey \
    --account-name $destStorageName \
    --source-account-key $storageKey \
    --source-account-name $storageName \
    --source-share xdm-assets \
    --destination-share xdm-assets \
    --recursive

echo " -- Storage account copied."

echo " --> Update existing storage account... "

echo "########## Running script ##########"

printf "az storage account update --resource-group $originResourceGroupName \\
    --name ${storageName} \\
    --default-action Deny\n"

echo "####################################"

az storage account update --resource-group $originResourceGroupName \
    --name ${storageName} \
    --default-action Deny

echo " -- Storage account updated."

echo " --> Update new storage account... "

echo "########## Running script ##########"

printf "az storage account update --resource-group $destinationResourceGroupName \\
    --name ${destStorageName} \\
    --default-action Deny\n"

echo "####################################"

az storage account update --resource-group $destinationResourceGroupName \
    --name ${destStorageName} \
    --default-action Deny

echo " -- New storage account updated."

echo " --> Cloning virtual network... "

currentNicProps=$(az network nic show --ids $(echo $currentVmProps | jq -r '.networkProfile.networkInterfaces[0].id'))
vnetId=$(echo $currentNicProps | jq -r '.ipConfigurations[0].subnet.id' | sed 's/\/subnets.*//')
currentVnetProps=$(az network vnet show --ids $vnetId)
currentPublicIpProps=$(az network public-ip show --ids $(echo $currentNicProps | jq -r '.ipConfigurations[0].publicIpAddress.id'))
appGwId=$(echo $currentNicProps | jq -r '.ipConfigurations[0].applicationGatewayBackendAddressPools[0].id' | sed 's/\/backendAddressPools.*//')
currentAppGwProps=$(az network application-gateway show --ids $appGwId)
currentNsgProps=$(az network nsg show --ids $(echo $currentNicProps | jq -r '.networkSecurityGroup.id'))

echo "########## Running script ##########"

printf "az network vnet create --name $destinationVnet \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network vnet create --name $destinationVnet \
    --resource-group $destinationResourceGroupName

echo " -- Virtual network cloned."

echo " --> Cloning subnets... "

echo "########## Running script ##########"

printf "az network vnet subnet create --name default \\
    --address-prefixes $(echo $currentVnetProps | jq -r '.subnets[0].addressPrefix') \\
    --vnet-name $destinationVnet \\
    --service-endpoints $(echo $currentVnetProps | jq -r '.subnets[0].serviceEndpoints[0].service')  $(echo $currentVnetProps | jq -r '.subnets[0].serviceEndpoints[1].service ') \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network vnet subnet create --name default \
    --address-prefixes $(echo $currentVnetProps | jq -r '.subnets[0].addressPrefix') \
    --vnet-name $destinationVnet \
    --service-endpoints $(echo $currentVnetProps | jq -r '.subnets[0].serviceEndpoints[0].service')  $(echo $currentVnetProps | jq -r '.subnets[0].serviceEndpoints[1].service ') \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network vnet subnet create --name $destinationSubnetGw \\
    --address-prefixes $(echo $currentVnetProps | jq -r '.subnets[1].addressPrefix') \\
    --vnet-name $destinationVnet \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network vnet subnet create --name $destinationSubnetGw \
    --address-prefixes $(echo $currentVnetProps | jq -r '.subnets[1].addressPrefix') \
    --vnet-name $destinationVnet \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network vnet subnet create --name $destinationSubnetSs \\
    --address-prefixes $(echo $currentVnetProps | jq -r '.subnets[2].addressPrefix') \\
    --vnet-name $destinationVnet \\
    --service-endpoints $(echo $currentVnetProps | jq -r '.subnets[2].serviceEndpoints[0].service') $(echo $currentVnetProps | jq -r '.subnets[2].serviceEndpoints[1].service ') \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network vnet subnet create --name $destinationSubnetSs \
    --address-prefixes $(echo $currentVnetProps | jq -r '.subnets[2].addressPrefix') \
    --vnet-name $destinationVnet \
    --service-endpoints $(echo $currentVnetProps | jq -r '.subnets[2].serviceEndpoints[0].service') $(echo $currentVnetProps | jq -r '.subnets[2].serviceEndpoints[1].service ') \
    --resource-group $destinationResourceGroupName

echo " -- Virtual subnets cloned."

echo " --> Cloning public ips... "

echo "########## Running script ##########"

printf "az network public-ip create --name $destinationIpA \\
    --sku $(echo $currentPublicIpProps | jq -r '.sku.name') \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network public-ip create --name $destinationIpA \
    --sku $(echo $currentPublicIpProps | jq -r '.sku.name') \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network public-ip create --name $destinationIp \\
    --sku $(echo $currentPublicIpProps | jq -r '.sku.name') \\
    --resource-group $destinationResourceGroupName \\
    --tags xdm-resource-type=public-ip\n"

echo "####################################"

az network public-ip create --name $destinationIp \
    --sku $(echo $currentPublicIpProps | jq -r '.sku.name') \
    --resource-group $destinationResourceGroupName \
    --tags xdm-resource-type=public-ip

echo " -- Public ips cloned."

echo " --> Cloning gateway... "

echo "########## Running script ##########"

printf "az network application-gateway create --name $destinationGw \\
    --http-settings-cookie-based-affinity $(echo $currentAppGwProps | jq -r '.backendHttpSettingsCollection[0].cookieBasedAffinity') \\
    --http-settings-port $(echo $currentAppGwProps | jq -r '.backendHttpSettingsCollection[0].port') \\
    --min-capacity $(echo $currentAppGwProps | jq -r '.autoscaleConfiguration.minCapacity') \\
    --public-ip-address $destinationIp \\
    --resource-group $destinationResourceGroupName \\
    --sku $(echo $currentAppGwProps | jq -r '.sku.name') \\
    --subnet $destinationSubnetGw \\
    --vnet-name $destinationVnet \\
    --tags xdm-resource-type=app-gw\n"

echo "####################################"

az network application-gateway create --name $destinationGw \
    --http-settings-cookie-based-affinity $(echo $currentAppGwProps | jq -r '.backendHttpSettingsCollection[0].cookieBasedAffinity') \
    --http-settings-port $(echo $currentAppGwProps | jq -r '.backendHttpSettingsCollection[0].port') \
    --min-capacity $(echo $currentAppGwProps | jq -r '.autoscaleConfiguration.minCapacity') \
    --public-ip-address $destinationIp \
    --resource-group $destinationResourceGroupName \
    --sku $(echo $currentAppGwProps | jq -r '.sku.name') \
    --subnet $destinationSubnetGw \
    --vnet-name $destinationVnet \
    --tags xdm-resource-type=app-gw

echo "########## Running script ##########"

printf "az network application-gateway frontend-port create --name $(echo $currentAppGwProps | jq -r '.frontendPorts[0].name') \\
    --gateway-name $destinationGw \\
    --port 180 \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway frontend-port create --name $(echo $currentAppGwProps | jq -r '.frontendPorts[0].name') \
    --gateway-name $destinationGw \
    --port 180 \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway frontend-port create --name $(echo $currentAppGwProps | jq -r '.frontendPorts[1].name') \\
    --gateway-name $destinationGw \\
    --port 18080 \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway frontend-port create --name $(echo $currentAppGwProps | jq -r '.frontendPorts[1].name') \
    --gateway-name $destinationGw \
    --port 18080 \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway address-pool create --name $destinationGwBap \\
    --gateway-name $destinationGw \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway address-pool create --name $destinationGwBap \
    --gateway-name $destinationGw \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway address-pool create --name $destinationAGwBap \\
    --gateway-name $destinationGw \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway address-pool create --name $destinationAGwBap \
    --gateway-name $destinationGw \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway http-listener create --name $(echo $currentAppGwProps | jq -r '.httpListeners[0].name') \\
    --gateway-name $destinationGw \\
    --frontend-port $(echo $currentAppGwProps | jq -r '.frontendPorts[0].name') \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway http-listener create --name $(echo $currentAppGwProps | jq -r '.httpListeners[0].name') \
    --gateway-name $destinationGw \
    --frontend-port $(echo $currentAppGwProps | jq -r '.frontendPorts[0].name') \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway http-listener create --name $(echo $currentAppGwProps | jq -r '.httpListeners[1].name') \\
    --gateway-name $destinationGw \\
    --frontend-port $(echo $currentAppGwProps | jq -r '.frontendPorts[1].name') \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway http-listener create --name $(echo $currentAppGwProps | jq -r '.httpListeners[1].name') \
    --gateway-name $destinationGw \
    --frontend-port $(echo $currentAppGwProps | jq -r '.frontendPorts[1].name') \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway rule create --name $(echo $currentAppGwProps | jq -r '.requestRoutingRules[1].name') \\
    --gateway-name $destinationGw \\
    --resource-group $destinationResourceGroupName \\
    --http-listener $(echo $currentAppGwProps | jq -r '.httpListeners[1].name') \\
    --address-pool $destinationAGwBap\n"

echo "####################################"

az network application-gateway rule create --name $(echo $currentAppGwProps | jq -r '.requestRoutingRules[1].name') \
    --gateway-name $destinationGw \
    --resource-group $destinationResourceGroupName \
    --http-listener $(echo $currentAppGwProps | jq -r '.httpListeners[1].name') \
    --address-pool $destinationAGwBap

echo "########## Running script ##########"

printf "az network application-gateway rule update --name $(echo $currentAppGwProps | jq -r '.requestRoutingRules[0].name') \\
    --gateway-name $destinationGw \\
    --resource-group $destinationResourceGroupName \\
    --http-listener $(echo $currentAppGwProps | jq -r '.httpListeners[0].name') \\
    --address-pool $destinationGwBap\n"

echo "####################################"

az network application-gateway rule update --name $(echo $currentAppGwProps | jq -r '.requestRoutingRules[0].name') \
    --gateway-name $destinationGw \
    --resource-group $destinationResourceGroupName \
    --http-listener $(echo $currentAppGwProps | jq -r '.httpListeners[0].name') \
    --address-pool $destinationGwBap

echo "########## Running script ##########"

printf "az network application-gateway address-pool delete --name appGatewayBackendPool \\
    --gateway-name $(echo $currentAppGwProps | jq -r '.name') \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway address-pool delete --name appGatewayBackendPool \
    --gateway-name $destinationGw \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway http-listener delete --name appGatewayHttpListener \\
    --gateway-name $destinationGw \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway http-listener delete --name appGatewayHttpListener \
    --gateway-name $destinationGw \
    --resource-group $destinationResourceGroupName

echo "########## Running script ##########"

printf "az network application-gateway frontend-port delete --name appGatewayFrontendPort \\
    --gateway-name $destinationGw \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway frontend-port delete --name appGatewayFrontendPort \
    --gateway-name $destinationGw \
    --resource-group $destinationResourceGroupName

frontendPort=$(echo $currentAppGwProps | jq -r '.frontendPorts[0].port')
isHttps=false

if [[ $frontendPort = 443 ]]; then
  isHttps=true
  frontendPort=80
fi

echo "########## Running script ##########"

printf "az network application-gateway frontend-port update --name $(echo $currentAppGwProps | jq -r '.frontendPorts[0].name') \\
    --gateway-name $destinationGw \\
    --port $frontendPort \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway frontend-port update --name $(echo $currentAppGwProps | jq -r '.frontendPorts[0].name') \
    --gateway-name $destinationGw \
    --port $frontendPort \
    --resource-group $destinationResourceGroupName

frontendPort=$(echo $currentAppGwProps | jq -r '.frontendPorts[1].port')

if [[ $frontendPort = 443 ]]; then
  isHttps=true
  frontendPort=80
fi

echo "########## Running script ##########"

printf "az network application-gateway frontend-port update --name $(echo $currentAppGwProps | jq -r '.frontendPorts[1].name') \\
    --gateway-name $destinationGw \\
    --port $frontendPort \\
    --resource-group $destinationResourceGroupName\n"

echo "####################################"

az network application-gateway frontend-port update --name $(echo $currentAppGwProps | jq -r '.frontendPorts[1].name') \
    --gateway-name $destinationGw \
    --port $frontendPort \
    --resource-group $destinationResourceGroupName

echo " -- Gateway cloned."

echo " --> Cloning network security group... "

echo "########## Running script ##########"

printf "az network nsg create --name $destinationNsg \\
    --resource-group $destinationResourceGroupName\n"

az network nsg create --name $destinationNsg \
    --resource-group $destinationResourceGroupName

echo "####################################"

echo "########## Running script ##########"

printf "az network nsg rule create --name $(echo $currentNsgProps | jq -r '.securityRules[0].name') \\
    --nsg-name $destinationNsg \\
    --priority $(echo $currentNsgProps | jq -r '.securityRules[0].priority') \\
    --access $(echo $currentNsgProps | jq -r '.securityRules[0].access') \\
    --direction $(echo $currentNsgProps | jq -r '.securityRules[0].direction') \\
    --destination-port-ranges \"$(echo $currentNsgProps | jq -r '.securityRules[0].destinationPortRange')\" \\
    --source-address-prefixes $(echo $currentNsgProps | jq -r '.securityRules[0].sourceAddressPrefix') \\
    --source-port-ranges \"$(echo $currentNsgProps | jq -r '.securityRules[0].sourcePortRange')\" \\
    --destination-address-prefixes \"*\" \\
    --protocol \"$(echo $currentNsgProps | jq -r '.securityRules[0].protocol')\" \\
    --resource-group $destinationResourceGroupName\n"

az network nsg rule create --name $(echo $currentNsgProps | jq -r '.securityRules[0].name') \
    --nsg-name $destinationNsg \
    --priority $(echo $currentNsgProps | jq -r '.securityRules[0].priority') \
    --access $(echo $currentNsgProps | jq -r '.securityRules[0].access') \
    --direction $(echo $currentNsgProps | jq -r '.securityRules[0].direction') \
    --destination-port-ranges "$(echo $currentNsgProps | jq -r '.securityRules[0].destinationPortRange')" \
    --source-address-prefixes $(echo $currentNsgProps | jq -r '.securityRules[0].sourceAddressPrefix') \
    --source-port-ranges "$(echo $currentNsgProps | jq -r '.securityRules[0].sourcePortRange')" \
    --destination-address-prefixes "*" \
    --protocol "$(echo $currentNsgProps | jq -r '.securityRules[0].protocol')" \
    --resource-group $destinationResourceGroupName

echo "####################################"

echo "########## Running script ##########"

printf "az network nsg rule create --name $(echo $currentNsgProps | jq -r '.securityRules[1].name') \\
    --nsg-name $destinationNsg \\
    --priority $(echo $currentNsgProps | jq -r '.securityRules[1].priority') \\
    --access $(echo $currentNsgProps | jq -r '.securityRules[1].access') \\
    --direction $(echo $currentNsgProps | jq -r '.securityRules[1].direction') \\
    --destination-port-ranges \"$(echo $currentNsgProps | jq -r '.securityRules[1].destinationPortRange')\" \\
    --source-address-prefixes $(echo $currentNsgProps | jq -r '.securityRules[1].sourceAddressPrefix') \\
    --source-port-ranges \"$(echo $currentNsgProps | jq -r '.securityRules[1].sourcePortRange')\" \\
    --destination-address-prefixes \"*\" \\
    --protocol \"$(echo $currentNsgProps | jq -r '.securityRules[1].protocol')\" \\
    --resource-group $destinationResourceGroupName\n"

az network nsg rule create --name $(echo $currentNsgProps | jq -r '.securityRules[1].name') \
    --nsg-name $destinationNsg \
    --priority $(echo $currentNsgProps | jq -r '.securityRules[1].priority') \
    --access $(echo $currentNsgProps | jq -r '.securityRules[1].access') \
    --direction $(echo $currentNsgProps | jq -r '.securityRules[1].direction') \
    --destination-port-ranges "$(echo $currentNsgProps | jq -r '.securityRules[1].destinationPortRange')" \
    --source-address-prefixes $(echo $currentNsgProps | jq -r '.securityRules[1].sourceAddressPrefix') \
    --source-port-ranges "$(echo $currentNsgProps | jq -r '.securityRules[1].sourcePortRange')" \
    --destination-address-prefixes "*" \
    --protocol "$(echo $currentNsgProps | jq -r '.securityRules[1].protocol')" \
    --resource-group $destinationResourceGroupName

echo "####################################"

echo " -- Network security group cloned."

echo " --> Cloning network interface... "

echo "########## Running script ##########"

printf "az network nic create --name $destinationNic \\
    --resource-group $destinationResourceGroupName \\
    --subnet default \\
    --vnet-name $destinationVnet \\
    --network-security-group $destinationNsg \\
    --gateway-name $destinationGw \\
    --app-gateway-address-pools $destinationAGwBap \\
    --public-ip-address $destinationIpA\n"

echo "####################################"
az network nic create --name $destinationNic \
    --resource-group $destinationResourceGroupName \
    --subnet default \
    --vnet-name $destinationVnet \
    --network-security-group $destinationNsg \
    --gateway-name $destinationGw \
    --app-gateway-address-pools $destinationAGwBap \
    --public-ip-address $destinationIpA

echo " -- Network interface cloned."

echo " --> Cloning databases..."

echo "########## Running script ##########"

if [[ $dbType = "PostgreSQL" ]]; then

  printf "az postgres server restore --restore-point-in-time $now \\
      --resource-group $destinationResourceGroupName \\
      --source-server $databaseServerId \\
      --name $destinationDatabaseServerName\n"

  echo "####################################"

  az postgres server restore --restore-point-in-time $now \
      --resource-group $destinationResourceGroupName \
      --source-server $databaseServerId \
      --name $destinationDatabaseServerName

  echo " --> Add network to database server... "

  echo "########## Running script ##########"

  printf "az postgres server vnet-rule create --resource-group $destinationResourceGroupName \\
      --name allow-$destinationVm \\
      --server-name $destinationDatabaseServerName \\
      --subnet default \\
      --vnet-name $destinationVnet\n"

  echo "####################################"

  az postgres server vnet-rule create --resource-group $destinationResourceGroupName \
      --name allow-$destinationVm \
      --server-name $destinationDatabaseServerName \
      --subnet default \
      --vnet-name $destinationVnet

  echo "########## Running script ##########"

  printf "az postgres server vnet-rule create --resource-group $destinationResourceGroupName \\
      --name allow-$destinationSs \\
      --server-name $destinationDatabaseServerName \\
      --subnet $destinationSubnetSs \\
      --vnet-name $destinationVnet\n"

  echo "####################################"

  az postgres server vnet-rule create --resource-group $destinationResourceGroupName \
      --name allow-$destinationSs \
      --server-name $destinationDatabaseServerName \
      --subnet $destinationSubnetSs \
      --vnet-name $destinationVnet

  echo "########## Running script ##########"

  printf "az postgres server update --resource-group $destinationResourceGroupName \\
      --name $destinationDatabaseServerName \\
      --tags xdm-database-type=PostgreSQL xdm-resource-type=db-server \n"

  echo "####################################"

  az postgres server update --resource-group $destinationResourceGroupName \
      --name $destinationDatabaseServerName \
      --tags xdm-database-type=PostgreSQL xdm-resource-type=db-server

  echo " -- Database server network added."

else

  printf "az sql server create --resource-group $destinationResourceGroupName \\
      --admin-password <admin-password> \\
      --admin-user $databaseAdminUser \\
      --name $destinationDatabaseServerName\n"

  echo "####################################"

  az sql server create --resource-group $destinationResourceGroupName \
      --admin-password $databaseServerPassword \
      --admin-user $databaseAdminUser \
      --name $destinationDatabaseServerName

  printf "az sql server update --resource-group $destinationResourceGroupName \\
      --name $destinationDatabaseServerName \\
      --set tags.xdm-database-type=SQLServer tags.xdm-resource-type=db-server \n"

  echo "####################################"

  az sql server update --resource-group $destinationResourceGroupName \
      --name $destinationDatabaseServerName \
      --set tags.xdm-database-type=SQLServer tags.xdm-resource-type=db-server

  for databaseName in $(az sql db list --ids $dbServerId | jq -r '.[] | select(.name != "master") | .name '); do
    echo "########## Running script ##########"

    printf "az sql db copy --resource-group $originResourceGroupName \\
        --dest-resource-group $destinationResourceGroupName \\
        --server $databaseServerName \\
        --dest-server $destinationDatabaseServerName \\
        --name $databaseName \\
        --dest-name $databaseName\n"

    echo "####################################"

    az sql db copy --resource-group $originResourceGroupName \
        --dest-resource-group $destinationResourceGroupName \
        --server $databaseServerName \
        --dest-server $destinationDatabaseServerName \
        --name $databaseName \
        --dest-name $databaseName
  done

  echo " --> Add network to database server... "

  echo "########## Running script ##########"

  printf "az sql server vnet-rule create --resource-group $destinationResourceGroupName \\
      --name allow-$destinationVm \\
      --server $destinationDatabaseServerName \\
      --subnet default \\
      --vnet-name $destinationVnet\n"

  echo "####################################"

  az sql server vnet-rule create --resource-group $destinationResourceGroupName \
      --name allow-$destinationVm \
      --server $destinationDatabaseServerName \
      --subnet default \
      --vnet-name $destinationVnet

  echo "########## Running script ##########"

  printf "az sql server vnet-rule create --resource-group $destinationResourceGroupName \\
      --name allow-$destinationSs \\
      --server $destinationDatabaseServerName \\
      --subnet $destinationSubnetSs \\
      --vnet-name $destinationVnet\n"

  echo "####################################"

  az sql server vnet-rule create --resource-group $destinationResourceGroupName \
      --name allow-$destinationSs \
      --server $destinationDatabaseServerName \
      --subnet $destinationSubnetSs \
      --vnet-name $destinationVnet

  echo " -- Database server network added."
fi

echo " -- $dbType databases cloned."

planName=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.sku')
imagePublisher=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.publisher')
imageOffer=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.offer')
imageVersion=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.exactVersion')

echo " --> Cloning Active VM... "

echo "########## Running script ##########"

printf "az vm create --resource-group $destinationResourceGroupName \\
    --name $destinationVm \\
    --admin-password <password> \\
    --admin-username $serverUser \\
    --authentication-type password \\
    --computer-name $destinationVm \\
    --image $imagePublisher:$imageOffer:$planName:$imageVersion \\
    --location $(echo $currentVmProps | jq -r '.location') \\
    --nics $destinationNic \\
    --plan-name $planName \\
    --plan-product $imageOffer \\
    --plan-publisher $imagePublisher \\
    --os-disk-caching $(echo $currentVmProps | jq -r '.storageProfile.osDisk.caching') \\
    --os-disk-size-gb $(echo $currentVmProps | jq -r '.storageProfile.osDisk.diskSizeGb') \\
    --size $(echo $currentVmProps | jq -r '.hardwareProfile.vmSize') \\
    --tags xdm-resource-type=vm-active\n"

echo "####################################"

az vm create --resource-group $destinationResourceGroupName \
    --name $destinationVm \
    --admin-password $serverPassword \
    --admin-username $serverUser \
    --authentication-type password \
    --computer-name $destinationVm \
    --image $imagePublisher:$imageOffer:$planName:$imageVersion \
    --location $(echo $currentVmProps | jq -r '.location') \
    --nics $destinationNic \
    --plan-name $planName \
    --plan-product $imageOffer \
    --plan-publisher $imagePublisher \
    --os-disk-caching $(echo $currentVmProps | jq -r '.storageProfile.osDisk.caching') \
    --os-disk-size-gb $(echo $currentVmProps | jq -r '.storageProfile.osDisk.diskSizeGb') \
    --size $(echo $currentVmProps | jq -r '.hardwareProfile.vmSize') \
    --tags xdm-resource-type=vm-active

echo " -- Active VM cloned."

echo " --> Cloning scale set image..."

echo "########## Running script ##########"

printf "az vmss create --resource-group $destinationResourceGroupName \\
    --name $destinationSs \\
    --admin-password <password> \\
    --admin-username $serverUser \\
    --authentication-type password \\
    --computer-name-prefix $instanceName-vm-p \\
    --image $imagePublisher:$imageOffer:$planName:$imageVersion \\
    --instance-count $(echo $currentSsProps | jq -r '.sku.capacity') \\
    --plan-name $planName \\
    --plan-product $imageOffer \\
    --plan-publisher $imagePublisher \\
    --location $(echo $currentSsProps | jq -r '.location') \\
    --app-gateway $destinationGw \\
    --backend-pool-name $destinationGwBap \\
    --subnet $destinationSubnetSs \\
    --vnet-name $destinationVnet \\
    --tags xdm-resource-type=ss-passive \\
    --upgrade-policy-mode $(echo $currentSsProps | jq -r '.upgradePolicy.mode') \\
    --vm-sku $(echo $currentSsProps | jq -r '.sku.name')\n"

echo "####################################"

az vmss create --resource-group $destinationResourceGroupName \
    --name $destinationSs \
    --admin-password "$serverPassword" \
    --admin-username "$serverUser" \
    --authentication-type password \
    --computer-name-prefix $instanceName-vm-p \
    --image $imagePublisher:$imageOffer:$planName:$imageVersion \
    --instance-count $(echo $currentSsProps | jq -r '.sku.capacity') \
    --plan-name $planName \
    --plan-product $imageOffer \
    --plan-publisher $imagePublisher \
    --location $(echo $currentSsProps | jq -r '.location') \
    --app-gateway $destinationGw \
    --backend-pool-name $destinationGwBap \
    --subnet $destinationSubnetSs \
    --vnet-name $destinationVnet \
    --tags xdm-resource-type=ss-passive \
    --upgrade-policy-mode $(echo $currentSsProps | jq -r '.upgradePolicy.mode') \
    --vm-sku $(echo $currentSsProps | jq -r '.sku.name')


#check we can find cpuautoscale
cpuautoscaleId=$(az monitor autoscale list --resource-group $originResourceGroupName  --query "[?name=='cpuautoscale'].id" -o tsv)
if [[ -n $cpuautoscaleId ]]
then
    cpuautoscale=$(az monitor autoscale show --name cpuautoscale --resource-group $originResourceGroupName)
    echo "########## Running script ##########"

    printf "az monitor autoscale create --resource $destinationSs \\
        --name $(echo $cpuautoscale | jq -r '.name') \\
        --resource-type Microsoft.Compute/virtualMachineScaleSets \\
        --min-count $(echo $cpuautoscale | jq -r '.profiles[0].capacity.minimum') \\
        --max-count $(echo $cpuautoscale | jq -r '.profiles[0].capacity.maximum') \\
        --count $(echo $cpuautoscale | jq -r '.profiles[0].capacity.default') \\
        --resource-group $destinationResourceGroupName\n"

    echo "####################################"

    az monitor autoscale create --resource $destinationSs \
        --name $(echo $cpuautoscale | jq -r '.name') \
        --resource-type Microsoft.Compute/virtualMachineScaleSets \
        --min-count $(echo $cpuautoscale | jq -r '.profiles[0].capacity.minimum') \
        --max-count $(echo $cpuautoscale | jq -r '.profiles[0].capacity.maximum') \
        --count $(echo $cpuautoscale | jq -r '.profiles[0].capacity.default') \
        --resource-group $destinationResourceGroupName

    echo "########## Running script ##########"

    printf "az monitor autoscale rule create --autoscale-name $(echo $cpuautoscale | jq -r '.name') \\
        --scale out 1 \\
        --condition \"Percentage CPU > 70 avg 10m\" \\
        --resource-group $destinationResourceGroupName\n"

    echo "####################################"

    az monitor autoscale rule create --autoscale-name $(echo $cpuautoscale | jq -r '.name') \
      --scale out 1 \
      --condition "Percentage CPU > 70 avg 10m" \
      --resource-group $destinationResourceGroupName

    echo "########## Running script ##########"

    printf "az monitor autoscale rule create --autoscale-name $(echo $cpuautoscale | jq -r '.name') \\
        --scale in 1 \\
        --condition \"Percentage CPU < 30 avg 10m\" \\
        --resource-group $destinationResourceGroupName\n"

    echo "####################################"

    az monitor autoscale rule create --autoscale-name $(echo $cpuautoscale | jq -r '.name') \
      --scale in 1 \
      --condition "Percentage CPU < 30 avg 10m" \
      --resource-group $destinationResourceGroupName
fi

echo " --Scale set image cloned."

echo " --> Add network to storage account... "

echo "########## Running script ##########"

printf "az storage account network-rule add --resource-group $destinationResourceGroupName \\
    --account-name $destStorageName \\
    --subnet default \\
    --vnet-name $destinationVnet\n"

echo "####################################"

az storage account network-rule add --resource-group $destinationResourceGroupName \
    --account-name $destStorageName \
    --subnet default \
    --vnet-name $destinationVnet

echo "########## Running script ##########"

printf "az storage account network-rule add --resource-group $destinationResourceGroupName \\
    --account-name $destStorageName \\
    --subnet $destinationSubnetSs \\
    --vnet-name $destinationVnet\n"

echo "####################################"

az storage account network-rule add --resource-group $destinationResourceGroupName \
    --account-name $destStorageName \
    --subnet $destinationSubnetSs \
    --vnet-name $destinationVnet

echo " -- Storage account network added."

echo " --> Mounting shared folder on cloned vm..."

echo "########## Running script ##########"

printf "az vm extension set --resource-group $destinationResourceGroupName \\
    --vm-name $destinationVm \\
    --name customScript \\
    --publisher Microsoft.Azure.Extensions \\
    --protected-settings {\"commandToExecute\": \"/usr/local/xdm/bin/init-active-shared-folder-ubuntu.sh \"$destStorageName\" <storage key> xdm-assets\"}\n"

echo "####################################"

az vm extension set --resource-group $destinationResourceGroupName \
  --vm-name $destinationVm \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/init-active-shared-folder-ubuntu.sh '$destStorageName' '$destStorageKey' xdm-assets"}'


versionDigits=(${imageVersion//./ })
fileName='config.properties'

if (( ${versionDigits[1]} < 3  )); then
  fileName='semarchy.xml'
fi

echo " --> Editing $fileName config to match new resources names..."

echo "########## Running script ##########"

printf "az vm extension set --resource-group $destinationResourceGroupName \\
    --vm-name $destinationVm \\
    --name customScript \\
    --publisher Microsoft.Azure.Extensions \\
    --protected-settings '{\"commandToExecute\": \"sed -i \"s/$databaseServerName/$destinationDatabaseServerName/\" /mnt/xdm/conf/$fileName \"}'\n"

echo "####################################"

az vm extension set --resource-group $destinationResourceGroupName \
  --vm-name $destinationVm \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --protected-settings '{"commandToExecute": "sed -i \"s/'$databaseServerName'/'$destinationDatabaseServerName'/\" /mnt/xdm/conf/'$fileName' "}'

echo " --> Running init script on scaleset..."

echo "########## Running script ##########"

printf "az vmss extension set \\
  --resource-group $destinationResourceGroupName \\
  --vmss-name $destinationSs \\
  --name customScript \\
  --publisher Microsoft.Azure.Extensions \\
  --protected-settings {\"commandToExecute\": \"/usr/local/xdm/bin/init-ss-ubuntu.sh --storage-name=\"$destStorageName\" --storage-key=<storage key> --storage-folder=xdm-assets --server-user=\"$serverUser\" --server-password=<server password> \"}\n"

echo "####################################"

az vmss extension set \
  --resource-group $destinationResourceGroupName \
  --vmss-name $destinationSs \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/init-ss-ubuntu.sh --storage-name=\"'$destStorageName'\" --storage-key=\"'$destStorageKey'\" --storage-folder=xdm-assets --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\""}'

echo "########## Running script ##########"

printf "./az-xdm-instance-reset-admin.sh --resource-group=$destinationResourceGroupName --admin-password=<admin-password>\n"

echo "####################################"

./az-xdm-instance-reset-admin.sh --resource-group=$destinationResourceGroupName --admin-password=$serverPassword

echo "########## Running script ##########"

printf "./az-xdm-instance-restart.sh --resource-group=$destinationResourceGroupName --admin-password=<admin-password>\n"

echo "####################################"

./az-xdm-instance-restart.sh --resource-group=$destinationResourceGroupName --admin-password=$serverPassword

echo " -- Clone script completed."

echo " -- Instance cloned successfully."

if $isHttps ; then
    echo " --> WARNING: You have HTTPS protocol configured on your original resourceGroup the script does not support HTTPS configuration so the HTTPS 443 port is replaced with the HTTP 80 port"
fi