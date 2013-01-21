<#
.SYNOPSIS
Set up, initialize, or reinitialize a database or subset of tables for Tesla.
.DESCRIPTION
This script reads Tesla config files for a master and slave agent and initializes tables.
Generally, this script should be run on a server that has the Tesla config files, which should be 
in the same datacenter as either the master or slave. If the amount of data you're initializing is 
small or you don't mind waiting, you can certainly run it from your own workstation. 
For Netezza slaves you'll need to already have things like the ssh keys and nzload scripts set up.
Make sure you have reviewed your configuration files fully before running this script, as one of the
things it does when setting up a new database is dropping all tables in the CT databases (but
not the master or slave databases).

This script requires powershell V2, as well as the .NET SMO tools installed, both of which are 
available from Microsoft. For initializing Netezza slaves, it also requires the NZOLEDB driver
which is available from IBM only if you own a Netezza server.
.PARAMETER masterconfigfile
Full path to the relevant Tesla Master agent configuration xml file.
.PARAMETER slaveconfigfile
Full path to the relevant Tesla Master agent configuration xml file
.PARAMETER tablelist
Optional comma separated list of tables to (re)initialize. If left out, all 
tables in the slave config file wll be (re)initialized. Use this when adding new tables to 
an existing setup.
.PARAMETER consolidatedctdb
Name of the consolidated shard database. Use only if you are doing a sharded setup with the
ShardCoordinator, and only in conjunction with the -newdatabase switch. You also only
need to specify this for one of the shards. This will cause the consolidated DB to be created.
This must match the relayDB that you put in your config files for ShardCoordinator and Slave agents.
.PARAMETER mappingsfile
Use for heterogeneous replication (i.e. Netezza slaves). This must be the full path to a file
for mapping data types from the master database type to slave database type. You should use the
same file you're going to use when running the slave agent. The mappings files that come with
Tesla should be sufficient but you can change them if you need to for your environment.
.PARAMETER newdatabase
Specify this if you are setting up a database for the first time. Don't specify this if you are
just adding new tables to an existing setup or reinitializing tables. This switch will cause all 
required CT databases to be created, and it will drop all tables in the CT databases as well.
It won't drop tables in the slave or master database other than tblDDLEvent on the master.
.PARAMETER notlast
Specify this switch when you are initializing multiple slaves, you must include this for all
but the last slave. Doing so will make sure the first batch is able to start correctly by
setting records in tblCTInitialize and tblCTVersion appropriately.
.PARAMETER notfirstshard
If you are doing a sharded setup, pass this flag for all but the first shard so that
the tables on the slave side don't get truncated or dropped in between each shard.
.PARAMETER reinitialize
Pass this to avoid dropping and recreating slave tables, instead just truncate and then 
reinitialize the data. The purpose of this is to maintain any custom indexes, table distributions
etc. you may have made on the slave side. Note that the schema for the slave MUST be correct already
for this to work.
.INPUTS
None
    You cannot pipe objects to Initialize-DB.
.OUTPUTS
   Writes console messages about its progress to the screen, but doesn't output any objects.
.EXAMPLE
Initialize a new MSSQL -> MSSQL tesla setup with no sharding:
.\Initialize-DB -masterconfigfile "D:\tesla\master.xml" -slaveconfigfile "D:\tesla\slave.xml" -newdatabase
.EXAMPLE
Initialize a new tesla setup with two MSSQL slaves and one Netezza slave. Note the use of -notlast and separate config files:
.\Initialize-DB -masterconfigfile "D:\tesla\master.xml" -slaveconfigfile "D:\tesla\MSSQLslave1.xml" -newdatabase -notlast
.\Initialize-DB -masterconfigfile "D:\tesla\master.xml" -slaveconfigfile "D:\tesla\NZslave1.xml" -mappingsfile "D:\tesla\data_mappings" -newdatabase -notlast 
.\Initialize-DB -masterconfigfile "D:\tesla\master.xml" -slaveconfigfile "D:\tesla\MSSQLslave2.xml" -newdatabase
.EXAMPLE
Initialize a new sharded setup with two MSSQL slaves. Carefully note the use of the notlast, notfirstshard and consolidatedctdb flags:
.\Initialize-DB -masterconfigfile "D:\tesla\master_shard1.xml" -slaveconfigfile "D:\tesla\MSSQLslave1.xml" -consolidatedctdb "CT_mydb_consolidated" -newdatabase -notlast 
.\Initialize-DB -masterconfigfile "D:\tesla\master_shard2.xml" -slaveconfigfile "D:\tesla\MSSQLslave1.xml" -newdatabase -notlast -notfirstshard
.\Initialize-DB -masterconfigfile "D:\tesla\master_shard1.xml" -slaveconfigfile "D:\tesla\MSSQLslave2.xml" -newdatabase
.\Initialize-DB -masterconfigfile "D:\tesla\master_shard2.xml" -slaveconfigfile "D:\tesla\MSSQLslave2.xml" -newdatabase -notfirstshard
.EXAMPLE
Add two new tables to an existing Tesla setup on two slaves:
.\Initialize-DB -masterconfigfile "D:\tesla\master.xml" -slaveconfigfile "D:\tesla\MSSQLslave1.xml" -tablelist "table1,table2" -notlast 
.\Initialize-DB -masterconfigfile "D:\tesla\master.xml" -slaveconfigfile "D:\tesla\MSSQLslave2.xml" -tablelist "table1,table2" 
.NOTES
Version History
v1.0   - Scott Sandler - Initial release
#>
Param(
 [Parameter(Mandatory=$true,Position=1)][string]$masterconfigfile,
 [Parameter(Mandatory=$true,Position=2)][string]$slaveconfigfile,
 [Parameter(Mandatory=$false,Position=3)][string]$tablelist,
 [Parameter(Mandatory=$false,Position=4)][string]$consolidatedctdb,
 [Parameter(Mandatory=$false,Position=5)][string]$mappingsfile,
 [switch]$newdatabase,
 [switch]$notlast,
 [switch]$notfirstshard,
 [switch]$reinitialize
)
Push-Location (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent)
Import-Module .\Modules\DB
$erroractionpreference = "Stop"

#########################
# Function definitions
#########################
Function Drop-AllTables {
[CmdletBinding()]
    param(
    [Parameter(Position=0, Mandatory=$true)] [string]$ServerInstance,
    [Parameter(Position=1, Mandatory=$true)] [string]$Database
    )
    $tables = invoke-sqlcmd2 -serverinstance $serverinstance -database $database `
    -query "select '[' + table_schema + '].[' + table_name + ']' as t from information_schema.tables where table_type = 'BASE TABLE'"
    $cmd = ""
    foreach ($table in $tables) {
        if ($table) {    
            $cmd += "DROP TABLE " + $table.t + "`r`nGO`r`n"
        }
    }
    if ($cmd -ne "") {    
        invoke-sqlcmd2 -serverinstance $serverinstance -database $database -query $cmd
    }
}

Function Drop-AllNetezzaTables {
[CmdletBinding()]
    param(
    [Parameter(Position=0, Mandatory=$true)] [string]$ServerInstance,
    [Parameter(Position=1, Mandatory=$true)] [string]$Database,
    [Parameter(Position=2, Mandatory=$true)] [string]$User,
    [Parameter(Position=3, Mandatory=$true)] [string]$Password
    )
    $result = invoke-netezzaquery -s $serverinstance -database $database -u $user -p $password `
        -query "SELECT TABLENAME FROM _V_TABLE WHERE OBJTYPE = 'TABLE';"
    foreach ($row in $result) {
        if (!$row) { continue }
        $table = $row.TABLENAME
        invoke-netezzaquery -s $serverinstance -database $database -u $user -p $password `
            -query "DROP TABLE $table"         
    }      
}

Function Create-DB ($server, $db, $type, $user, $password) {
    if ($type -eq "MSSQL") {
        $query = "if not exists (select 1 from sys.databases where name = '$db')
        CREATE DATABASE $db
        GO
        ALTER DATABASE $db SET RECOVERY SIMPLE
        GO
        if not exists (select 1 from sys.syslogins where name = '$user') 
    	CREATE LOGIN [$user] WITH PASSWORD='$password', DEFAULT_DATABASE=[$db], DEFAULT_LANGUAGE=[us_english], CHECK_EXPIRATION=OFF, CHECK_POLICY=OFF
        GO
        USE $db
        GO
        if not exists (SELECT 1 from sys.sysusers where name = '$user')
        	CREATE USER [$user] FOR LOGIN [$user]
        EXEC sp_addrolemember N'db_owner', N'$user'
        "
        
        invoke-sqlcmd2 -serverinstance $server -query $query
    } elseif ($type -eq "Netezza") {
        $query = "select 1 from _v_database where database = '" + $db.ToUpper() + "'"
        $exists = invoke-netezzaquery -s $server -database $db -u $user -p $password -query $query
        if ($exists -eq $null) {
            $query = "CREATE DATABASE $db"
            invoke-netezzaquery -s $server -database $db -u $user -p $password -query $query
        }
    }
}

####################
# Initialize variables based on arguments
####################

$tablestoinclude = @()
if ($tablelist -ne $null) {
    $tablestoinclude = $tablelist.Split(",")
}

Write-Host "Loading slave XML settings"
[xml]$xml = Get-Content $slaveconfigfile

$slave = $xml.SelectSingleNode("/conf/slave").InnerText
$slavetype = $xml.SelectSingleNode("/conf/slaveType").InnerText
$slavedb = $xml.SelectSingleNode("/conf/slaveDB").InnerText
$slavectdb = $xml.SelectSingleNode("/conf/slaveCTDB").InnerText
$slaveuser = $xml.SelectSingleNode("/conf/slaveUser").InnerText
$slavepassword = $xml.SelectSingleNode("/conf/slavePassword").InnerText
$nzloadscriptpath = $xml.SelectSingleNode("/conf/nzLoadScriptPath").InnerText
$netezzastringlength = $xml.SelectSingleNode("/conf/netezzaStringLength").InnerText
$bcppath = $xml.SelectSingleNode("/conf/bcpPath").InnerText
$plinkpath = $xml.SelectSingleNode("/conf/plinkPath").InnerText
$netezzauser = $xml.SelectSingleNode("/conf/netezzaUser").InnerText
$netezzaprivatekeypath = $xml.SelectSingleNode("/conf/netezzaPrivateKeyPath").InnerText

$relay = $xml.SelectSingleNode("/conf/relayServer").InnerText
$relaytype = $xml.SelectSingleNode("/conf/relayType").InnerText
$relaydb = $xml.SelectSingleNode("/conf/relayDB").InnerText
$relayuser = $xml.SelectSingleNode("/conf/relayUser").InnerText
$relaypassword = $xml.SelectSingleNode("/conf/relayPassword").InnerText
$tables = $xml.SelectSingleNode("/conf/tables")
Write-Host "Loading master XML settings"
[xml]$xml = Get-Content $masterconfigfile

$master = $xml.SelectSingleNode("/conf/master").InnerText
$mastertype = $xml.SelectSingleNode("/conf/masterType").InnerText
$masterdb = $xml.SelectSingleNode("/conf/masterDB").InnerText
$masterctdb = $xml.SelectSingleNode("/conf/masterCTDB").InnerText
$masteruser = $xml.SelectSingleNode("/conf/masterUser").InnerText
$masterpassword = $xml.SelectSingleNode("/conf/masterPassword").InnerText
$sharding = $xml.SelectSingleNode("/conf/sharding").InnerText
if ($sharding -eq "true") {
    $sharding = $true
} else {
    $sharding = $false
}

###########################
# This is where we start actually doing stuff
###########################
Write-Host "initializing ctripledes decrypter"
$ctripledes = new-object ctripledes

if ($newdatabase) {
    Write-Host "enabling change tracking on master database"
    $query = "IF NOT EXISTS (select 1 from sys.change_tracking_databases WHERE database_id = DB_ID('$masterdb'))
	ALTER DATABASE [$masterdb] SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 4 DAYS)"
    invoke-sqlcmd2 -serverinstance $master -database $masterdb -query $query
    
    Write-Host "tblDDLEvent on master database"
    $query = "IF OBJECT_ID('dbo.tblDDLEvent') IS NOT NULL
	DROP TABLE tblDDLEVent

    CREATE TABLE [dbo].[tblDDLevent](
    	[DdeID] [int] IDENTITY(1,1) NOT NULL,
    	[DdeTime] [datetime] NOT NULL DEFAULT GETDATE(),
    	[DdeEvent] [nvarchar](max) NULL,
    	[DdeTable] [varchar](255) NULL,
    	[DdeEventData] [xml] NULL,
    PRIMARY KEY CLUSTERED 
    (
    	[DdeID] ASC
    )WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
    ) ON [PRIMARY]"
    invoke-sqlcmd2 -serverinstance $master -database $masterdb -query $query
    $query = "IF EXISTS (select 1 from sys.triggers WHERE name = 'ddl_trig')
	DROP TRIGGER ddl_trig ON DATABASE
    GO
    --this one is important!
    SET ANSI_PADDING ON
    GO
    CREATE TRIGGER [ddl_trig]
    ON DATABASE 
    FOR ALTER_TABLE, RENAME
    AS
    SET NOCOUNT ON

    DECLARE @data XML, @EventType nvarchar(max), @TargetobjectType nvarchar(max),@objectType nvarchar(max) ;
    DECLARE @event nvarchar(max), @tablename nvarchar(max)
    SET @data = EVENTDATA();
    SELECT @event = EVENTDATA().value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'nvarchar(MAX)'); 
    SELECT @EventType = EVENTDATA().value('(/EVENT_INSTANCE/EventType)[1]', 'nvarchar(MAX)')

    IF @EventType = 'RENAME'
    BEGIN
       SELECT @TargetobjectType = EVENTDATA().value('(/EVENT_INSTANCE/TargetObjectType)[1]', 'nvarchar(MAX)'), 
       @objectType = EVENTDATA().value('(/EVENT_INSTANCE/ObjectType)[1]', 'nvarchar(MAX)')
       
       IF @TargetobjectType = 'TABLE' AND @objectType = 'COLUMN'  
    		SELECT @tablename = EVENTDATA().value('(/EVENT_INSTANCE/TargetObjectName)[1]', 'varchar(256)');      
    END
    ELSE
    		SELECT @tablename = EVENTDATA().value('(/EVENT_INSTANCE/ObjectName)[1]', 'varchar(256)');		


    IF @tablename IS NOT NULL AND EXISTS (select 1 from sys.change_tracking_tables  where object_id = object_id(@tablename))	
    INSERT tblDDLevent (DdeEvent, DdeTable, DdeEventData)
    		SELECT @event,
    		@tablename, 
    		@data	

    ;
    GO

    ENABLE TRIGGER [ddl_trig] ON DATABASE
    GO"
    invoke-sqlcmd2 -serverinstance $master -database $masterdb -query $query

    Write-Host "creating $masterctdb on server $master"
    Create-DB $master $masterctdb $mastertype $masteruser $ctripledes.Decrypt($masterpassword)

    Write-Host "dropping all tables on $masterctdb on server $master"
    Drop-AllTables $master $masterctdb

    #create tblCTInitialize
    $query = "CREATE TABLE dbo.tblCTInitialize (
    tableName varchar(100) NOT NULL PRIMARY KEY,
    iniStartTime datetime NOT NULL,
    inProgress bit NOT NULL,
    iniFinishTime datetime NULL,
    nextSynchVersion bigint NOT NULL
    )"

    Write-Host "creating tblCTInitialize on $masterctdb on server $master"
    invoke-sqlcmd2 -serverinstance $master -database $masterctdb -query $query

    Write-Host "creating $relaydb on server $relay"
    Create-DB $relay $relaydb $relaytype $relayuser $ctripledes.Decrypt($relaypassword)

    Write-Host "dropping all tables on $relaydb on server $relay"
    Drop-AllTables $relay $relaydb

    #tblCTversion has no identity on sharded CT dbs
    if ($sharding) {
        $identexpression = ""
    } else {
        $identexpression = "IDENTITY(1,1)"
    }
$query = @"
CREATE TABLE [dbo].[tblCTVersion](
	[CTID] [bigint] $identexpression NOT NULL PRIMARY KEY,
	[syncStartVersion] [bigint] NULL,
	[syncStopVersion] [bigint] NULL,
	[syncStartTime] [datetime] NULL,
	[syncStopTime] [datetime] NULL,
	[syncBitWise] [int] NOT NULL DEFAULT (0)
) 

CREATE TABLE [dbo].[tblCTSlaveVersion](
	[CTID] [bigint] NOT NULL,
	[slaveIdentifier] [varchar](100) NOT NULL,
	[syncStartVersion] [bigint] NULL,
	[syncStopVersion] [bigint] NULL,
	[syncStartTime] [datetime] NULL,
	[syncStopTime] [datetime] NULL,
	[syncBitWise] [int] NOT NULL DEFAULT (0),
	PRIMARY KEY (CTID, slaveIdentifier)
) 
"@

    Write-Host "creating tblCTVersion/tblCTSlaveVersion on $relaydb on server $relay"

    invoke-sqlcmd2 -serverinstance $relay -database $relaydb -query $query

    Write-Host "getting CHANGE_TRACKING_CURRENT_VERSION() from master"
    $result = invoke-sqlcmd2 -serverinstance $master -database $masterdb -query "SELECT CHANGE_TRACKING_CURRENT_VERSION() as v"
    $version = $result.v

    if ($sharding -and $consolidatedctdb.length -gt 0) {
        Write-Host "creating $consolidatedctdb on server $relay"
        Create-DB $relay $consolidatedctdb $relaytype $relayuser $ctripledes.Decrypt($relaypassword)
        
        Write-Host "dropping all tables on $consolidatedctdb on server $relay"
        Drop-AllTables $relay $consolidatedctdb
$query = @"
CREATE TABLE [dbo].[tblCTVersion](
	[CTID] [bigint] IDENTITY(1,1) NOT NULL PRIMARY KEY,
	[syncStartVersion] [bigint] NULL,
	[syncStopVersion] [bigint] NULL,
	[syncStartTime] [datetime] NULL,
	[syncStopTime] [datetime] NULL,
	[syncBitWise] [int] NOT NULL DEFAULT (0)
) 

CREATE TABLE [dbo].[tblCTSlaveVersion](
	[CTID] [bigint] NOT NULL,
	[slaveIdentifier] [varchar](100) NOT NULL,
	[syncStartVersion] [bigint] NULL,
	[syncStopVersion] [bigint] NULL,
	[syncStartTime] [datetime] NULL,
	[syncStopTime] [datetime] NULL,
	[syncBitWise] [int] NOT NULL DEFAULT (0),
	PRIMARY KEY (CTID, slaveIdentifier)
) 
"@
        Write-Host "creating tblCTVersion/tblCTSlaveVersion on $consolidatedctdb on server $relay"
        invoke-sqlcmd2 -serverinstance $relay -database $consolidatedctdb -query $query
        
        Write-Host "writing version number $version to consolidated tblCTVersion"
        $query = "INSERT INTO tblCTVersion (syncStartVersion, syncStartTime, syncStopVersion, syncBitWise) 
        VALUES ($version, '1/1/1990', $version, 7);"
        $result = invoke-sqlcmd2 -serverinstance $relay -database $consolidatedctdb 
    }

    if ($sharding) {
        Write-Host "writing version number $version to sharded tblCTVersion"
        $query = "INSERT INTO tblCTVersion (CTID, syncStartVersion, syncStartTime, syncStopVersion, syncBitWise) 
        VALUES (1, $version, '1/1/1990', $version, 7);"
        $result = invoke-sqlcmd2 -serverinstance $relay -database $relaydb 
    } else {
        Write-Host "writing version number $version to tblCTVersion"
        $query = "INSERT INTO tblCTVersion (syncStartVersion, syncStartTime, syncStopVersion, syncBitWise) 
        VALUES ($version, '1/1/1990', $version, 7);"
        $result = invoke-sqlcmd2 -serverinstance $relay -database $relaydb 
    }

    Write-Host "creating $slavectdb on server $slave"
    Create-DB $slave $slavectdb $slavetype $slaveuser $ctripledes.Decrypt($slavepassword)

    Write-Host "dropping all tables on $slavectdb on server $slave"
    Drop-AllTables $slave $slavectdb

    Write-Host "creating $slavedb on server $slave"
    Create-DB $slave $slavedb $slavetype $slaveuser $ctripledes.Decrypt($slavepassword)
}

#foreach table, AddTable-ToCT
foreach ($tableconf in $tables.SelectNodes("table")) {
    if ($tablestoinclude.length -gt 0 -and $tablestoinclude -notcontains $tableconf.name) {
        continue
    }
    $modifiers = $tableconf.SelectNodes("columnModifier") 
    $columnmodifiers = $null 
    foreach ($modifier in $modifiers) {
        if (!$modifier) {
            continue
        }
        if ($columnmodifiers -eq $null) {
            "yup"
            $columnmodifiers = "<root>"
        }
        $columnmodifiers += [string]$modifier.OuterXML        
    }
    if ($columnmodifiers -ne $null) {
        $columnmodifiers += "</root>"
    }
    $columns = $tableconf.SelectSingleNode("columnList")
    $columnlist = $null
    if ($columns -ne $null) {
        $columnlist = [string]$columns.OuterXML
    }
    Write-Host ("Calling .\AddTable-ToCT for table " + $tableconf.name)
    #many of these params (i.e. the netezza ones) may be null or empty but that's fine
    #note, switches can be specfied using a bool with the : syntax, i.e. -switch:$true
    .\AddTable-ToCT -master $master -masterdb $masterdb -slave $slave -slavedb $slavedb -slavetype $slavetype `
        -table $tableconf.name -schema $tableconf.schemaname -user $slaveuser -password $slavepassword `
        -columnlist $columnlist -columnmodifiers $columnmodifiers -netezzastringlength $netezzastringlength `
        -mappingsfile $mappingsfile -sshuser $sshuser -pkpath $pkpath -plinkpath $plinkpath `
        -nzloadscript $nzloadscript  -bcppath $bcppath -reinitalize:$reinitialize -notlast:$notlast -notfirstshard:$notfirstshard
}


#update row of tblCTVersion, setting syncbitwise to 7

if ($newdatabase) {
    if (!$notlast) {
        write-host "marking initial batch as done on relay"
        invoke-sqlcmd2 -serverinstance $relay -database $relaydb -query "update tblCTVersion set syncbitwise = 7, syncstoptime = getdate()"
        write-host "marking any in progress rows in tblCTInitialize as comlpete"
        invoke-sqlcmd2 -serverinstance $master -database $masterctdb -query "update tblCTInitialize set inprogress = 0, inifinishtime = GETDATE() where inprogress = 1"
        if ($sharding -and $consolidatedctdb.length -gt 0) {
            write-host "marking initial batch as done on relay consolidated table"
            invoke-sqlcmd2 -serverinstance $relay -database $consolidatedctdb -query "update tblCTVersion set syncbitwise = 7, syncstoptime = getdate()"
        }
    }
}