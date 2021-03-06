﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Data;
using TeslaSQL.DataUtils;
namespace TeslaSQL.DataCopy {
    public class TestDataCopy : IDataCopy {

        private TestDataUtils sourceDataUtils { get; set; }
        private TestDataUtils destDataUtils { get; set; }

        public TestDataCopy(TestDataUtils sourceDataUtils, TestDataUtils destDataUtils) {
            this.sourceDataUtils = sourceDataUtils;
            this.destDataUtils = destDataUtils;
        }

        public void CopyTable(string sourceDB, string table, string schema, string destDB, int timeout, string destTableName = null, string originalTableName = null) {
            //by default the dest table will have the same name as the source table
            destTableName = (destTableName == null) ? table : destTableName;
            //create a copy of the source table (data and schema)
            DataTable copy = sourceDataUtils.testData.Tables[schema + "." + table, sourceDataUtils.GetTableSpace(sourceDB)].Copy();
            //change the namespace to be the dest server
            copy.TableName = schema + "." + destTableName;
            copy.Namespace = destDataUtils.GetTableSpace(destDB);
            //add it to the dataset
            destDataUtils.testData.Tables.Add(copy);
        }


        public void CopyTableDefinition(string sourceDB, string sourceTableName, string schema, string destDB, string destTableName, string originalTableName = null) {
            throw new NotImplementedException();
        }
    }
}
