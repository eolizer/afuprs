create or replace package "PKG_CORE_VERSIONING" as

    type t_tabrec_type
      is table of raw(16)
      index by varchar2(128);

    function GetTableVersioningFlag (
        modelID in  raw,
        tableName in varchar
    ) return number;

    function GetLastRevision (
        tableName in varchar,
        byField in varchar,
        fieldValue in varchar
    ) return number;


    procedure StoreRevisionDiff (
        tableName       in  varchar,
        objInstanceId   in  raw,
        objInstanceRev  in  number   
    );
    
    
    procedure StoreObjectWithVersioning (
        crudAction      in  varchar,
        tableName       in  varchar,        
        modelID         in  raw,
        taskID          in  raw default null,
        revInvalReason  in raw default null,
        objData         in  clob,     
        revCreationTS   in timestamp default null,
        revInvalTS      in  timestamp default null
    );

    procedure InvalidateRevision (
        tableName in varchar,
        objInstanceId in raw,
        revisionNumber in number,
        taskId in raw default null,
        invalidationReason in raw default null,
        invalidationTimestamp in timestamp default null
    );

    function GetObjectInstanceRevisionChain (
        objInstanceId   raw,
        timePoint       varchar
    ) return clob;

end "PKG_CORE_VERSIONING";
/