# azure-template
Management scripts for xDM Solution

## Add new databases or schemas in the existing database server (SQL or PG)
The administrator downloads and runs the following script in the Azure Portal within his tenant:
`
az-xdm-instance-add-database.sh
	--resource-group=resource-group-name
	--db-name=database-name
	--db-password=database-password
--db-server-password=db-server-password
--admin-password=admin-password
`
This script:
* Uses env variables for commonly used values if not available in the command.
** XDM_RESOURCE_GROUP
** XDM_ADMIN_PASSWORD
** XDM_DB_SERVER_PASSWORD
** XDM_DB_PASSWORD
* Prompts for passwords when they are not passed on the command line and the env variable is not set.
* Adds databases to the existing deployment for SQL Server using a template
* Adds databases to the existing PostgreSQL machine using SQL scripting, started on the active instance
* Adds and persists datasource to the existing configuration using Shell scripting started on the active instance

## Upgrade an existing xDM instance to a latest version
The administrator downloads and runs the following script in the Azure Portal within his tenant:
`
az-xdm-instance-upgrade.sh 
	--resource-group=resource-group-name
	--admin-password=admin-password
	--xdm-version=xdm-version
`

## Restart an existing xDM instance
The administrator can also downloads and runs the following script in the Azure Portal within his tenant to restart the instance after a change:
`
az-xdm-instance-restart.sh 
	--resource-group  resource-group-name
	--admin-password admin-password
`

