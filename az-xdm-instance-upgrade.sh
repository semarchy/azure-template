#!/bin/bash -e

# Help menu
print_help() {
cat <<-HELP
Usage: $0 <--xdm-version=version> <--resource-group=resource-group-name> [--admin-password=admin-password] [--db-server-password=db-server-password] [--repo-ro-password=repo-ro-password] [--backup]
HELP
exit 1
}

resourceGroupName=$XDM_RESOURCE_GROUP
serverPassword=$XDM_ADMIN_PASSWORD
databaseServerPassword=$XDM_DB_SERVER_PASSWORD
repositoryReadOnlyUserPassword=$XDM_RO_USER_PASSWORD

backup=false
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
    --db-server-password=*)
        databaseServerPassword="${1#*=}"
        ;;
    --repo-ro-password=*)
        repositoryReadOnlyUserPassword="${1#*=}"
        ;;
    --backup*)
        backup=true
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

export AZURE_HTTP_USER_AGENT='pid-ee0cf0e2-6610-4481-9d19-e1db68621749-partnercenter'

if ! $(az group exists --name $resourceGroupName)
then 
	echo " !! resource group $resourceGroupName not found."
    exit 1;
fi

versionDigits=(${version//./ })

imagePublisher=semarchy
imageOffer=xdm-solution-vm

if (( ${#versionDigits[@]} == 3 )); then
    if [[ ${versionDigits[2]} = "preview" ]]; then
        planName=${versionDigits[0]}'_'${versionDigits[1]}'_preview'
        imageVersion=1.200.3
        imageOffer=xdm-solution-vm-preview
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
currentSsProps=$(az vmss show --name $scaleSetName --resource-group $resourceGroupName)
scaleSetId=$(echo $currentSsProps | jq -r '.id')
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

dbServerId=$(az resource list --tag xdm-resource-type=db-server --query "[?resourceGroup=='$resourceGroupName'].id" -o tsv)
if [[ -z $dbServerId ]]
then
    echo " !! Database server not found in $resourceGroupName."
    exit 1;
fi

# retrieve current db properties
currentDbServerProps=$(az resource show --ids $dbServerId)
dbType=$(echo $currentDbServerProps | jq -r '.tags."xdm-database-type"')
echo " -- $dbType database server found ($dbServerId)."

databaseAdminUser=$(echo $currentDbServerProps | jq -r '.properties.administratorLogin')
databaseServerName=$(echo $currentDbServerProps | jq -r '.name')

now=$(date --iso-8601=seconds)

echo " --> Checking admin credentials..."
vmName=$(echo $currentVmProps | jq -r '.name')

echo "########## Running script ##########"

printf "az vm extension set --resource-group $resourceGroupName \\
    --vm-name $vmName \\
    --name customScript \\
    --publisher Microsoft.Azure.Extensions \\
    --protected-settings '{\"commandToExecute\": \"/usr/local/xdm/bin/check-admin-credentials-ubuntu.sh --server-user=\"'$serverUser'\" --server-password=\"<password>\"\"}'\n"

echo "####################################"

az vm extension set --resource-group $resourceGroupName \
  --vm-name $vmName \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/check-admin-credentials-ubuntu.sh --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\""}'

echo " --> Upgrade can proceed. Moving current xDM instance to new version..."
az vm image terms accept --publisher $imagePublisher --offer $imageOffer --plan $planName

oldPlanName=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.sku')
oldImagePublisher=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.publisher')
oldImageOffer=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.offer')
oldImageVersion=$(echo $currentVmProps | jq -r '.storageProfile.imageReference.exactVersion')

majorUpgrade=false
oldVersionDigits=(${oldImageVersion//./ })

if [[ ${versionDigits[1]} = ${oldVersionDigits[1]} ]]; then
  echo " --> Executing a minor upgrade..."
elif (( versionDigits[1] > oldVersionDigits[1] )); then
  if [[ ${versionDigits[1]} = 3 ]]; then

    if ! $backup ; then
      while true; do
          read -p "Are you performing the upgrade on a cloned or a backed up instance? " yn
          case $yn in
              [Yy]* ) break;;
              [Nn]* ) while true; do
                        read -p "Are you sure you want to proceed without cloning or adding --backup option? " yn
                        case $yn in
                            [Yy]* ) break;;
                            [Nn]* ) exit;;
                            * ) echo "Please answer yes or no.";;
                        esac
                      done
                      break;;
              * ) echo "Please answer yes or no.";;
          esac
      done
    fi

    echo " --> Executing a major upgrade..."
    majorUpgrade=true
    if [[ -z $databaseServerPassword ]]
    then
        # Read Password
        echo -n Database Server Password:
        read -s databaseServerPassword
        echo
    fi

    if [[ -z $repositoryReadOnlyUserPassword ]]
    then
        # Read Password
        echo -n Repository read-only user Password:
        read -s repositoryReadOnlyUserPassword
        echo
    fi
  else
    echo " !! Version upgrade is only possible from 5.1.x or 5.2.x to 5.3.y"
    exit 1;
  fi
else
  echo " !! Version downgrade is not supported"
  exit 1;
fi

if $backup ; then

  echo " --> Creating backup for databases..."

  if [[ $dbType = "PostgreSQL" ]]; then
    echo "########## Running script ##########"

    printf "az postgres server restore --restore-point-in-time $now \\
        --resource-group $resourceGroupName \\
        --source-server $databaseServerName \\
        --name $databaseServerName-backup\n"

    echo "####################################"

    az postgres server restore --restore-point-in-time $now \
        --resource-group $resourceGroupName \
        --source-server $databaseServerName \
        --name $databaseServerName-backup
  else
    for databaseName in $(az sql db list --ids $dbServerId | jq -r '.[] | select(.name != "master") | .name '); do
      echo "########## Running script ##########"

      printf "az sql db restore --time $now \\
          --resource-group $resourceGroupName \\
          --server $databaseServerName \\
          --name $databaseName \\
          --dest-name $databaseName-backup\n"

      echo "####################################"

      az sql db restore --time $now \
          --resource-group $resourceGroupName \
          --server $databaseServerName \
          --name $databaseName \
          --dest-name $databaseName-backup
    done
  fi

  echo " --> Creating backup scale set image..."

  echo "########## Running script ##########"

  printf "az vmss create --resource-group $resourceGroupName \\
      --name $scaleSetName-backup \\
      --admin-password <password> \\
      --admin-username $serverUser \\
      --authentication-type password \\
      --app-gateway '' \\
      --computer-name-prefix $(echo $currentSsProps | jq -r '.virtualMachineProfile.osProfile.computerNamePrefix') \\
      --image $oldImagePublisher:$oldImageOffer:$oldPlanName:$oldImageVersion \\
      --instance-count 1 \\
      --plan-name $oldPlanName \\
      --plan-product $oldImageOffer \\
      --plan-publisher $oldImagePublisher \\
      --location $(echo $currentSsProps | jq -r '.location') \\
      --subnet $(echo $currentSsProps | jq -r '.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id') \\
      --tags xdm-resource-type=ss-passive-backup \\
      --upgrade-policy-mode $(echo $currentSsProps | jq -r '.upgradePolicy.mode') \\
      --vm-sku $(echo $currentSsProps | jq -r '.sku.name')\n"

  echo "####################################"

  az vmss create --resource-group $resourceGroupName \
      --name $scaleSetName-backup \
      --admin-password "$serverPassword" \
      --admin-username "$serverUser" \
      --authentication-type password \
      --app-gateway "" \
      --computer-name-prefix $(echo $currentSsProps | jq -r '.virtualMachineProfile.osProfile.computerNamePrefix') \
      --image $oldImagePublisher:$oldImageOffer:$oldPlanName:$oldImageVersion \
      --instance-count 1 \
      --plan-name $oldPlanName \
      --plan-product $oldImageOffer \
      --plan-publisher $oldImagePublisher \
      --location $(echo $currentSsProps | jq -r '.location') \
      --subnet $(echo $currentSsProps | jq -r '.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id') \
      --tags xdm-resource-type=ss-passive-backup \
      --upgrade-policy-mode $(echo $currentSsProps | jq -r '.upgradePolicy.mode') \
      --vm-sku $(echo $currentSsProps | jq -r '.sku.name')

  echo "########## Running script ##########"

  printf "az vmss extension set \\
    --resource-group $resourceGroupName \\
    --vmss-name $scaleSetName-backup \\
    --name customScript \\
    --publisher Microsoft.Azure.Extensions \\
    --protected-settings {\"commandToExecute\": \"/usr/local/xdm/bin/init-ss-ubuntu.sh --storage-name=\"$storageName\" --storage-key=<storage key> --storage-folder=xdm-assets --server-user=\"$serverUser\" --server-password=<server password> \"}\n"

  echo "####################################"

  az vmss extension set \
    --resource-group $resourceGroupName \
    --vmss-name $scaleSetName-backup \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/init-ss-ubuntu.sh --storage-name=\"'$storageName'\" --storage-key=\"'$storageKey'\" --storage-folder=xdm-assets --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\""}'

  echo " -- Backup scale set image created."

  echo " --> Creating backup Active VM..."

  echo "########## Running script ##########"

  printf "az vm create --resource-group $resourceGroupName \\
      --name $vmName-backup \\
      --admin-password <password> \\
      --admin-username $serverUser \\
      --authentication-type password \\
      --computer-name $(echo $currentVmProps | jq -r '.osProfile.computerName') \\
      --image $oldImagePublisher:$oldImageOffer:$oldPlanName:$oldImageVersion \\
      --plan-name $oldPlanName \\
      --plan-product $oldImageOffer \\
      --plan-publisher $oldImagePublisher \\
      --location $(echo $currentVmProps | jq -r '.location') \\
      --nsg '' \\
      --public-ip-address '' \\
      --os-disk-caching $(echo $currentVmProps | jq -r '.storageProfile.osDisk.caching') \\
      --os-disk-size-gb $(echo $currentVmProps | jq -r '.storageProfile.osDisk.diskSizeGb') \\
      --size $(echo $currentVmProps | jq -r '.hardwareProfile.vmSize') \\
      --tags xdm-resource-type=vm-active-backup\n"

  echo "####################################"

  az vm create --resource-group $resourceGroupName \
      --name $vmName-backup \
      --admin-password "$serverPassword" \
      --admin-username "$serverUser" \
      --authentication-type password \
      --computer-name $(echo $currentVmProps | jq -r '.osProfile.computerName') \
      --image $oldImagePublisher:$oldImageOffer:$oldPlanName:$oldImageVersion \
      --plan-name $oldPlanName \
      --plan-product $oldImageOffer \
      --plan-publisher $oldImagePublisher \
      --location $(echo $currentVmProps | jq -r '.location') \
      --nsg "" \
      --public-ip-address "" \
      --os-disk-caching $(echo $currentVmProps | jq -r '.storageProfile.osDisk.caching') \
      --os-disk-size-gb $(echo $currentVmProps | jq -r '.storageProfile.osDisk.diskSizeGb') \
      --size $(echo $currentVmProps | jq -r '.hardwareProfile.vmSize') \
      --tags xdm-resource-type=vm-active-backup

  echo " -- Backup Active VM created."
fi

if $majorUpgrade ; then
  echo " --> Saving semarchy.xml and tomcat-users.xml to semarchy.xml-old and tomcat-users.xml-old..."
  vmName=$(echo $currentVmProps | jq -r '.name')

  echo "########## Running script ##########"

  printf "az vm extension set --resource-group $resourceGroupName \\
      --vm-name $vmName \\
      --name customScript \\
      --publisher Microsoft.Azure.Extensions \\
      --protected-settings '{\"commandToExecute\": \"mv /mnt/xdm/conf/semarchy.xml /mnt/xdm/conf/semarchy.xml-old ; mv /mnt/xdm/conf/tomcat-users.xml /mnt/xdm/conf/tomcat-users.xml-old\"}'\n"

  echo "####################################"

  az vm extension set --resource-group $resourceGroupName \
    --vm-name $vmName \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --protected-settings '{"commandToExecute": "mv /mnt/xdm/conf/semarchy.xml /mnt/xdm/conf/semarchy.xml-old ; mv /mnt/xdm/conf/tomcat-users.xml /mnt/xdm/conf/tomcat-users.xml-old"}'

  echo " --> Deleting obsolete scale set image ($scaleSetName)..."
  az vmss delete --ids $scaleSetId
  az resource wait --deleted --ids $scaleSetId
  echo " -- Obsolete scale set image deleted."

  echo " --> Re-creating scale set image..."

  echo "########## Running script ##########"
  appGateway=$(echo $currentSsProps | jq -r '.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].applicationGatewayBackendAddressPools[0].id' | sed 's/\/backendAddressPools.*//')
  backendPoolName=$(echo $currentSsProps | jq -r '.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].applicationGatewayBackendAddressPools[0].id' | sed 's/.*\/backendAddressPools\///')

  printf "az vmss create --resource-group $resourceGroupName \\
      --name $scaleSetName \\
      --admin-password <password> \\
      --admin-username $serverUser \\
      --authentication-type password \\
      --app-gateway $appGateway \\
      --backend-pool-name $backendPoolName \\
      --computer-name-prefix $(echo $currentSsProps | jq -r '.virtualMachineProfile.osProfile.computerNamePrefix') \\
      --image $imagePublisher:$imageOffer:$planName:$imageVersion \\
      --instance-count $(echo $currentSsProps | jq -r '.sku.capacity') \\
      --plan-name $planName \\
      --plan-product $imageOffer \\
      --plan-publisher $imagePublisher \\
      --location $(echo $currentSsProps | jq -r '.location') \\
      --subnet $(echo $currentSsProps | jq -r '.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id') \\
      --tags xdm-resource-type=ss-passive \\
      --upgrade-policy-mode $(echo $currentSsProps | jq -r '.upgradePolicy.mode') \\
      --vm-sku $(echo $currentSsProps | jq -r '.sku.name')\n"

  echo "####################################"

  az vmss create --resource-group $resourceGroupName \
      --name $scaleSetName \
      --admin-password "$serverPassword" \
      --admin-username "$serverUser" \
      --authentication-type password \
      --app-gateway $appGateway \
      --backend-pool-name $backendPoolName \
      --computer-name-prefix $(echo $currentSsProps | jq -r '.virtualMachineProfile.osProfile.computerNamePrefix') \
      --image $imagePublisher:$imageOffer:$planName:$imageVersion \
      --instance-count $(echo $currentSsProps | jq -r '.sku.capacity') \
      --plan-name $planName \
      --plan-product $imageOffer \
      --plan-publisher $imagePublisher \
      --location $(echo $currentSsProps | jq -r '.location') \
      --subnet $(echo $currentSsProps | jq -r '.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id') \
      --tags xdm-resource-type=ss-passive \
      --upgrade-policy-mode $(echo $currentSsProps | jq -r '.upgradePolicy.mode') \
      --vm-sku $(echo $currentSsProps | jq -r '.sku.name')

  echo " -- scale set image created."
else
  echo " --> Updating scale set image..."
  az vmss update --name $scaleSetName --resource-group $resourceGroupName --set virtualMachineProfile.storageProfile.imageReference.version=$imageVersion
  echo " -- Scale set updated."
fi

echo " --> Deleting obsolete active VM ($vmActiveId)..."
az vm delete --ids $vmActiveId --yes
az resource wait --deleted --ids $vmActiveId
echo " -- Obsolete active VM deleted."

echo " --> Re-creating Active VM..."

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

echo "########## Running script ##########"

if $majorUpgrade ; then
  printf "az vm extension set \\
    --resource-group $resourceGroupName \\
    --vm-name $vmName \\
    --name customScript \\
    --publisher Microsoft.Azure.Extensions \\
    --protected-settings {\"commandToExecute\": \"/usr/local/xdm/bin/upgrade-instance-ubuntu.sh --storage-name=\"$storageName\" --storage-key=<storage key> --storage-folder=xdm-assets --server-user=\"$serverUser\" --server-password=<server password> --db-type='$dbType' --db-admin=\"$databaseAdminUser\" --db-password=<db password> --db-server=\"$databaseServerName\" --repo-ro-password=<repo ro password> --major-upgrade \"}\n"

  echo "####################################"

  az vm extension set \
    --resource-group $resourceGroupName \
    --vm-name $vmName \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/upgrade-instance-ubuntu.sh --storage-name=\"'$storageName'\" --storage-key=\"'$storageKey'\" --storage-folder=xdm-assets --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\" --db-type='$dbType' --db-admin=\"'$databaseAdminUser'\" --db-password=\"'$databaseServerPassword'\" --db-server=\"'$databaseServerName'\" --repo-ro-password=\"'$repositoryReadOnlyUserPassword'\" --major-upgrade"}'

  echo "########## Running script ##########"

  printf "az vmss extension set \\
    --resource-group $resourceGroupName \\
    --vmss-name $scaleSetName \\
    --name customScript \\
    --publisher Microsoft.Azure.Extensions \\
    --protected-settings {\"commandToExecute\": \"/usr/local/xdm/bin/init-ss-ubuntu.sh --storage-name=\"$storageName\" --storage-key=<storage key> --storage-folder=xdm-assets --server-user=\"$serverUser\" --server-password=<server password> \"}\n"

  echo "####################################"

  az vmss extension set \
    --resource-group $resourceGroupName \
    --vmss-name $scaleSetName \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/init-ss-ubuntu.sh --storage-name=\"'$storageName'\" --storage-key=\"'$storageKey'\" --storage-folder=xdm-assets --server-user=\"'$serverUser'\" --server-password=\"'$serverPassword'\""}'
else
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
fi

echo " -- Upgrade script completed."

echo " -- Instance upgraded successfully."