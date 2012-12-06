﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Xml;

namespace TeslaSQL {
    class DDLEvent {
        public int ddeID { get; set; }

        public XmlDocument eventData { get; set; }       

        /// <summary>
        /// Constructor used when initializing this object based on data from a DDL trigger
        /// </summary>
        /// <param name="ddeID">Unique id for this event</param>
        /// <param name="eventData">XmlDocument from the EVENTDATA() SQL function</param>
        public DDLEvent(int ddeID, XmlDocument eventData) {
            this.ddeID = ddeID;
            this.eventData = eventData;
        }

        public List<SchemaChange> Parse(TableConf[] t_array, TServer server, string dbName) {
            var schemaChanges = new List<SchemaChange>();
            string columnName;
            string tableName;
            SchemaChangeType changeType;
            DataType dataType;
            SchemaChange sc;
            string newColumnName;
            string eventType = eventData.SelectSingleNode("EVENT_INSTANCE/EventType").InnerText;

            XmlNode node;
            if (eventType == "ALTER_TABLE") {
                node = eventData.SelectSingleNode("EVENT_INSTANCE/AlterTableActionList");
            } else if (eventType == "RENAME") {
                node = eventData.SelectSingleNode("EVENT_INSTANCE/Parameters");
            } else {
                //this is a DDL event type that we don't care about publishing, so ignore it
                return schemaChanges;
            }

            if (node.FirstChild.Name == "Param") {
                tableName = eventData.SelectSingleNode("/EVENT_INSTANCE/TargetObjectName").InnerText;
            } else {
                tableName = eventData.SelectSingleNode("/EVENT_INSTANCE/ObjectName").InnerText;
            }

            string schemaName = eventData.SelectSingleNode("/EVENT_INSTANCE/SchemaName").InnerText;
            
            //String.Compare method returns 0 if the strings are equal, the third "true" flag is for a case insensitive comparison
            //Get table config object
            TableConf t = t_array.SingleOrDefault(item => String.Compare(item.Name, tableName, ignoreCase: true) == 0);
            
            if (t == null) {
                //the DDL event applies to a table not in our config, so we just ignore it
                return schemaChanges;
            }     
            

            switch (node.FirstChild.Name) {
                case "Param":
                    changeType = SchemaChangeType.Rename;                    
                    columnName = eventData.SelectSingleNode("/EVENT_INSTANCE/ObjectName").InnerText;
                    newColumnName = eventData.SelectSingleNode("/EVENT_INSTANCE/NewObjectName").InnerText;
                    sc = new SchemaChange(changeType, schemaName, tableName, columnName, newColumnName);
                    schemaChanges.Add(sc);
                    break;
                case "Alter":                    
                    changeType = SchemaChangeType.Modify;                    
                    foreach (XmlNode xColumn in eventData.SelectNodes("/EVENT_INSTANCE/AlterTableActionList/Alter/Columns/Name")) {                        
                        columnName = xColumn.InnerText;
                        dataType = DataUtils.GetDataType(server, dbName, tableName, columnName);
                        sc = new SchemaChange(changeType, schemaName, tableName, columnName, null, dataType);
                        schemaChanges.Add(sc);
                    }
                    break;
                case "Create":
                    changeType = SchemaChangeType.Add;
                    tableName = eventData.SelectSingleNode("/EVENT_INSTANCE/ObjectName").InnerText;
                    foreach (XmlNode xColumn in eventData.SelectNodes("/EVENT_INSTANCE/AlterTableActionList/Create/Columns/Name")) {
                        columnName = xColumn.InnerText;
                        //if column list is specified, only publish schema changes if the column is already in the list. we don't want
                        //slaves adding a new column that we don't plan to publish changes for. 
                        if (t.columnList != null && t.columnList.Contains(columnName)) {
                            dataType = DataUtils.GetDataType(server, dbName, tableName, columnName);
                            sc = new SchemaChange(changeType, schemaName, tableName, columnName, null, dataType);
                            schemaChanges.Add(sc);
                        }
                    }                    
                    break;
                case "Drop":
                    changeType = SchemaChangeType.Drop;
                    tableName = eventData.SelectSingleNode("/EVENT_INSTANCE/ObjectName").InnerText;
                    foreach (XmlNode xColumn in eventData.SelectNodes("/EVENT_INSTANCE/AlterTableActionList/Drop/Columns/Name")) {
                        //if columnlist for this table is specified
                        columnName = xColumn.InnerText;
                        dataType = DataUtils.GetDataType(server, dbName, tableName, columnName);
                        sc = new SchemaChange(changeType, schemaName, tableName, columnName, null, dataType);
                        schemaChanges.Add(sc);
                    }   
                    break;
            }
            return schemaChanges;
        }
    }

}
