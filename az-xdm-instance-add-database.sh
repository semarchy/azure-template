#!/bin/bash -e

# Help menu
print_help() {
cat <<-HELP
Usage: $0 <--db-name=database-name> [--resource-group=resource-group-name] [--db-password=database-password] [--db-server-password=database-server-password] [--admin-password=admin-password]
HELP
exit 1
}

serverPassword=$XDM_ADMIN_PASSWORD
resourceGroupName=$XDM_RESOURCE_GROUP
databaseServerPassword=$XDM_DB_SERVER_PASSWORD
databasePassword=$XDM_DB_PASSWORD
# Parse Command Line Arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resource-group=*)
        resourceGroupName="${1#*=}"
        ;;
    --db-name=*)
        databaseUser="${1#*=}"
        ;;
    --db-password=*)
        databasePassword="${1#*=}"
        ;;
    --db-server-password=*)
        databaseServerPassword="${1#*=}"
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

if [[ -z $databaseUser || -z $resourceGroupName ]]
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

if [[ -z $databaseServerPassword ]]
then
    # Read Password
    echo -n Database Server Password: 
    read -s databaseServerPassword
    echo
fi

if [[ -z $databasePassword ]]
then
    # Read Password
    echo -n Database Password: 
    read -s databasePassword
    echo
fi

export AZURE_HTTP_USER_AGENT='pid-b196565f-e39e-5007-9fb7-63dd46818292'

dbServerId=$(az resource list --tag xdm-resource-type=db-server --query "[?resourceGroup=='$resourceGroupName'].id" -o tsv)
if [[ -z $dbServerId ]]
then
    echo " !! Database server not found in $resourceGroupName."
    exit 1;
fi

currentDbServerProps=$(az resource show --ids $dbServerId)
dbType=$(echo $currentDbServerProps | jq -r '.tags."xdm-database-type"')
echo " -- $dbType database server found ($dbServerId)."

databaseAdminUser=$(echo $currentDbServerProps | jq -r '.properties.administratorLogin')
databaseServerName=$(echo $currentDbServerProps | jq -r '.name')

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

# check password is ok
appGwName=$(az resource list --tag xdm-resource-type=app-gw --query "[?resourceGroup=='$resourceGroupName'].name" -o tsv)
if [[ -z $appGwName ]]
then
    echo " !! Application gateway not found in $resourceGroupName."
    exit 1;
fi

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

httpStatus=$(curl --insecure -s -o /dev/null -w "%{http_code}" -u $serverUser:$serverPassword $fProtocol://$fAddress:$fPort/manager/text/list)

if (( $httpStatus != 200 )); then
    echo " !! Invalid admin credentials (response status: $httpStatus)."
    exit 1;
else 
    echo " -- Admin credentials are valid."
fi

#create database if sqlserver
if [[ $dbType = "SQLServer" ]]; then
    echo " --> Creating Azure SQL database..."
    az sql db create \
        --resource-group $resourceGroupName \
        --name $databaseUser \
        --server $databaseServerName \
        --service-objective S3
fi

echo " --> Adding database using active VM..."
az vm extension set \
  --resource-group $resourceGroupName \
  --vm-name $vmName \
  --name customScript \
  --publisher Microsoft.Azure.Extensions \
  --force-update \
  --protected-settings '{"commandToExecute": "/usr/local/xdm/bin/update-datasource-ubuntu.sh --db-type='$dbType' --server-user='$serverUser' --server-password='$serverPassword' --db-admin='$databaseAdminUser' --db-password='$databaseServerPassword' --ds-password='$databasePassword' --db-server='$databaseServerName' --ds-user='$databaseUser'"}'
echo " -- Active VM updated."

echo " --> Restarting scale set..."
az vmss reimage --name $scaleSetName --resource-group $resourceGroupName
echo " -- Scale set updated."

echo " -- Database added successfully."