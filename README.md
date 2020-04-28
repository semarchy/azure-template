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
* [Restart the instance](#restart-the-instance-az-xdm-instance-upgrade)
* [Change the admin password](#change-the-instance-admin-password)

### Add a new database: az-xdm-instance-add-database ###

The az-xdm-instance-add-database script creates a new database/schema - for example, for a new data location - and then automatically configures and restarts the Semarchy instance to take into account this new database.

```
az-xdm-instance-add-database.sh
    [--resource-group=resource-group-name]
    [--admin-password=admin-password]
    [--db-server-password=database-server-password]
    --db-name=<database-name>
    [--db-password=database-password]
```

Parameters:

* `--db-name`: The name of the new database. This value is used for the name of the database created, for the user created for this database, as well as for the name of the datasource configured in the application server to connect this database.

Optional Parameters:

* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.
* `--admin-password`: The password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.
* `--db-admin-password`: The password of the database server administrator. The password specified in the `XDM_DB_SERVER_PASSWORD` environment variable is used by default.
* `--db-password`: The password of the new database user to create. The password specified in the `XDM_DB_PASSWORD` environment variable is used by default.

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP`, ` XDM_ADMIN_PASSWORD`, `XDM_DB_SERVER_PASSWORD`and `XDM_DB_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.
* The script adds a database to the *Azure SQL Database Server* (SQL Server) configured in the Semarchy xDM instance or adds a database to the existing *Azure Database for PostgreSQL Server* using SQL scripting.
* The script adds and persists datasource to the existing configuration using Shell scripting, started on the active virtual machine instance.

### Upgrade the instance: az-xdm-instance-upgrade ###

The az-xdm-instance-upgrade script upgrades the Semarchy instance to a given version.

```
az-xdm-instance-upgrade.sh
    [--resource-group=resource-group-name]
    [--admin-password=admin-password]
    [--xdm-version=version]
```

Example: Upgrade the instance in the xdm-production resource group to version 5.2.3.

```
az-xdm-instance-upgrade.sh --resource-group=xdm-production --xdm-version=5.2.3
```

Example: Upgrade the instance in the xdm-production resource group to latest 5.1 patch version.

```
az-xdm-instance-upgrade.sh --resource-group=xdm-production --xdm-version=5.1
```

Optional Parameters:

* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.
* `--admin-password`: The password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.
* `--xdm-version`: The Semarchy version to which you want to upgrade. This version may be provided in the following format:
    * A 2 digits minor version of Semarchy (e.g.: 5.2): In that case, the template upgrades the latest patch of the minor version specified.
    * A 3 digits patch version of Semarchy (e.g.: 5.2.1). In that case, the template upgrades to that product version.
    * If you do not specify the version, then the latest patch of the currently deployed minor version is installed

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP` and `XDM_ADMIN_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.


### Restart the instance: az-xdm-instance-upgrade ###

The az-xdm-instance-upgrade script restarts the Semarchy instance, for example after modifying its configuration.

```
az-xdm-instance-restart.sh
    [--resource-group=resource-group-name]
    [--admin-password=admin-password]
```

**Example**: Restart the instance in the xdm-production resource group.

```
az-xdm-instance-restart.sh --resource-group=xdm-production
```

Optional Parameters:
* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.
* `--admin-password`: The password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP` and `XDM_ADMIN_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.

### Change the instance admin password ###

The az-xdm-instance-reset-admin script changes the admin password of the Semarchy instance.

```
az-xdm-instance-reset-admin.sh 
    [--resource-group=resource-group-name]
    [--admin-password=new-admin-password]
```

**Example**:

```
az-xdm-instance-reset-admin.sh --resource-group=xdm-production
```

Optional Parameters:
* `--resource-group`: The resource group into which the instance is deployed. The resource group specified in the `XDM_RESOURCE_GROUP` environment variable is used by default.
* `--admin-password`: The new password of the virtual machine administrator. The password specified in the `XDM_ADMIN_PASSWORD` environment variable is used by default.

**NOTES**:
* The script uses the following environment variables for commonly used values if not available in the command: `XDM_RESOURCE_GROUP` and `XDM_ADMIN_PASSWORD`.
* The script prompts for passwords when they are not passed on the command line and the environments variables are not set.

## License ##

These scripts are distributed under the MIT license found in the LICENSE file.
