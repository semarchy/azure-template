# Semarchy xDM Solution Template - Management Scripts #

This repository contains the management scripts to manage an instance deployed with the Semarchy xDM Solution Template in Microsoft Azure.


## Overview ##

**[Semarchy xDM](https://www.semarchy.com)** is the Intelligent Data Hub platform for Master Data Management (MDM), Reference Data Management (RDM), Application Data Management (ADM), Data Quality, and Data Governance. It provides all the features for data quality, data validation, data matching, de-duplication, data authoring, workflows, and more.

The **[Semarchy xDM Solution Template Offer](https://portal.azure.com/#create/semarchy.xdm-solution)** deploys a production-ready Intelligent Data Hub infrastructure on Microsoft Azure, with a choice of database technologies, the possibility to enable high-availability, etc. Such a deployment is suitable for development, test, or production purposes.

To install the template: 
* Find it on the [Azure Marketplace](https://portal.azure.com/#create/semarchy.xdm-solution)
* Read the [documentation](https://www.semarchy.com/doc/semarchy-xdm/semaz.html)

## Management Scripts ##

These scripts support the following operations:

* [Add a new database to the instance](#add-a-new-database-az-xdm-instance-add-database)
* [Upgrade the instance](#upgrade-the-instance-az-xdm-instance-upgrade)
* [Clone the instance](#clone-the-instance-az-xdm-instance-clone)
* [Restart the instance](#restart-the-instance-az-xdm-instance-restart)
* [Change the admin password](#change-the-instance-admin-password)

### Add a new database: az-xdm-instance-add-database ###

The az-xdm-instance-add-database script creates a new database/schema - for example, for a new data location - and then automatically configures and restarts the Semarchy instance to take into account this new database.

```
az-xdm-instance-add-database.sh
    --db-name=database-name
    --resource-group=resource-group-name
    [--admin-password=admin-password]
    [--db-server-password=database-server-password]
    [--db-password=database-password]
```

Parameters:

* `--db-name`: The name of the new database. This value is used for the name of the database created, for the user created for this database, as well as for the name of the datasource configured in the application server to connect this database.
* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.

Optional Parameters:

* `--admin-password`: The password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.
* `--db-admin-password`: The password of the database server administrator. The password specified in the `XDM_DB_SERVER_PASSWORD` environment variable is used by default.
* `--db-password`: The password of the new database user to create. The password specified in the `XDM_DB_PASSWORD` environment variable is used by default.

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP`, `XDM_ADMIN_PASSWORD`, `XDM_DB_SERVER_PASSWORD`and `XDM_DB_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.
* The script adds a database to the *Azure SQL Database Server* (SQL Server) configured in the Semarchy xDM instance or adds a database to the existing *Azure Database for PostgreSQL Server* using SQL scripting.
* The script adds and persists datasource to the existing configuration using Shell scripting, started on the active virtual machine instance.

### Clone the instance: az-xdm-instance-clone ###

The az-xdm-instance-clone script clones the Semarchy instance to a new resource group.

```
az-xdm-instance-clone.sh
    --origin-resource-group=origin-resource-group-name
    --destination-resource-group=destination-resource-group-name
    --instance-name=instance-name
    [--admin-password=admin-password]
    [--db-server-password=db-server-password]
```

Example: Clone the instance in the xdm-production resource group to xdm-production-clone resource group with instance name xdm1

```
az-xdm-instance-clone.sh --origin-resource-group=xdm-production --destination-resource-group=xdm-production-clone --instance-name=xdm1
```

Parameters:
* `--origin-resource-group`: The resource group from which the instance is cloned. The resource group specified in the `XDM_ORIGIN_RESOURCE_GROUP` environment variable is used by default.
* `--destination-resource-group`: The resource group where the instance is cloned. The resource group specified in the `XDM_DESTINATION_RESOURCE_GROUP` environment variable is used by default. If the provided resource group exists, it is used, otherwise it is created by the script (requires the user who runs the script to have R/W privileges on resource groups).
* `--instance-name`: The new instance name that will be used as prefix for resource names. The instance name specified in the `XDM_INSTANCE_NAME` environment variable is used by default.

Optional Parameters:

* `--admin-password`: The password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.
* `--db-server-password`: The password of the database administrator. The password specified in the `XDM_DB_SERVER_PASSWORD` environment variable is used by default.

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_ORIGIN_RESOURCE_GROUP`, `XDM_DESTINATION_RESOURCE_GROUP`, `XDM_INSTANCE_NAME`, `XDM_ADMIN_PASSWORD`, `XDM_DB_SERVER_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.
* The script generates a unique string as a suffix for database name and storage account name. If the scripts fails due to an already existing database name or storage account name, relaunch the script to generate a new suffix.

### Upgrade the instance: az-xdm-instance-upgrade ###

The az-xdm-instance-upgrade script upgrades the Semarchy instance to a given version.

```
az-xdm-instance-upgrade.sh
    --resource-group=resource-group-name
    --xdm-version=version
    [--admin-password=admin-password]
    [--db-server-password=db-server-password]
    [--repo-ro-password=repo-ro-password]
    [--backup]
```

Example: Upgrade the instance in the xdm-production resource group to version 5.2.3.

```
az-xdm-instance-upgrade.sh --resource-group=xdm-production --xdm-version=5.2.3
```

Example: Upgrade the instance in the xdm-production resource group to latest 5.1 patch version.

```
az-xdm-instance-upgrade.sh --resource-group=xdm-production --xdm-version=5.1
```

Example: Upgrade the instance in the xdm-production resource group to latest 5.3 patch version and creating backup resources.

```
az-xdm-instance-upgrade.sh --resource-group=xdm-production --xdm-version=5.3 --backup
```

Parameters:
* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.
* `--xdm-version`: The Semarchy version to which you want to upgrade. This version may be provided in the following format:
    * A 2 digits minor version of Semarchy (e.g.: 5.2): In that case, the template upgrades the latest patch of the minor version specified.
    * A 3 digits patch version of Semarchy (e.g.: 5.2.1). In that case, the template upgrades to that product version.
    * If you do not specify the version, then the latest patch of the currently deployed minor version is installed

Optional Parameters:

* `--admin-password`: The password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.
* `--db-server-password`: The password of the database administrator. The password specified in the `XDM_DB_SERVER_PASSWORD` environment variable is used by default.
* `--repo-ro-password`: The password of the repository read-only user (only applicable to 5.3+). The password specified in the `XDM_RO_USER_PASSWORD` environment variable is used by default.
* `--backup`: Use this option to add the creation of databases, virtual machines and scale set images backup resources. The backup is disabled by default.

**NOTES**:
* It is recommended to perform major upgrades either on a cloned instance (offsite upgrade) by running the `az-xdm-instance-clone` script prior to `az-xdm-instance-upgrade`, or on a backed-up instance (onsite upgrade) by using the `--backup` option.
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP`, `XDM_ADMIN_PASSWORD`, `XDM_DB_SERVER_PASSWORD` and `XDM_RO_USER_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.

### Restart the instance: az-xdm-instance-restart ###

The az-xdm-instance-restart script restarts the Semarchy instance, for example after modifying its configuration.

```
az-xdm-instance-restart.sh
    --resource-group=resource-group-name
    [--admin-password=admin-password]
```

**Example**: Restart the instance in the xdm-production resource group.

```
az-xdm-instance-restart.sh --resource-group=xdm-production
```
Parameters:
* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.

Optional Parameters:
* `--admin-password`: The password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP` and `XDM_ADMIN_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.

### Change the instance admin password ###

The az-xdm-instance-reset-admin script changes the admin password of the VM instance and Semarchy instance (only for 5.1.x and 5.2.x).

```
az-xdm-instance-reset-admin.sh 
    --resource-group=resource-group-name
    [--admin-password=new-admin-password]
```

**Example**:

```
az-xdm-instance-reset-admin.sh --resource-group=xdm-production
```

Parameters:
* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.

Optional Parameters:
* `--admin-password`: The new password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP` and `XDM_ADMIN_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.

## License ##

These scripts are distributed under the MIT license found in the LICENSE file.
