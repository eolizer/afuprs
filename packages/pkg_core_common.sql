create or replace package "PKG_CORE_COMMON" as
    
    function GetCharCTS return varchar;

    function GetJsonKeys (
        jsonDict    in clob
    ) return json_array_t;

    function GetInsertSQLFromJson (
        tableName   in  varchar,
        jsonRec in  clob
    ) return varchar;

    function GetUpdateSQLFromJson (
        tableName   in  varchar,
        jsonRec in  clob        
    ) return varchar;

    function RegisterModelInstance (
        modelId raw
    ) return raw;

    function GetObjectModelIdByName (
        modelName varchar
    ) return raw;

    function RegisterObjectInstance (
        objectId raw
    ) return raw;

    function GetObjectIdByName (
        objectName varchar
    ) return raw;

    function GetObjectIdByInstance (
        objInstanceId raw
    ) return raw;

    function GetObjectModelSchema (
        objectId    raw
    ) return clob;

    function GetObjectComponentTables(
        objectId    raw
    ) return varchar2;

end "PKG_CORE_COMMON";
/