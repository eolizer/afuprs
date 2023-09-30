create or replace package body "PKG_CORE_VERSIONING" as

    
    -- Функція повертає атрибут версіонування таблиці:
    --   1 - версіонувати
    --   0 - не версіонувати
    -- Аргументи:
    --   @ modelID - GUID моделі, до якої належить таблиця
    --   @ tableName - ім'я таблиці    
    function GetTableVersioningFlag (
        modelID     in  raw,
        tableName   in  varchar
    ) return number
    as
        ver_flag    number(1);
        model_json  clob;
        versioning  varchar2(5);    
    begin
        begin
            select objms.OBJECT_MODEL into model_json from CORE_OBM__OBJECT_MODELS objms where objms.ID = modelId;              
            select om.versioning into versioning from json_table(model_json,
                '$.components[*]' columns (
                    table_name varchar(255) path '$.table',
                    versioning varchar(5) path '$.versioning'
                )) om where om.table_name=tableName;
            exception
                when NO_DATA_FOUND then
                    raise_application_error(-20403, 'GetTableVersioningFlag: No data found');
        end;

        if versioning='true' then
            ver_flag:=1;
        else
            ver_flag:=0;
        end if;    
        return ver_flag;
    end;
    

    -- Функція повертає номер останньої ревізії об'єкту (макс. значення)
    --  @ tableName
    --  @ byField
    --  @ fieldValue
    function GetLastRevision (
        tableName   in varchar,
        byField     in varchar,
        fieldValue  in varchar
    ) return number
    as
        v_sql           varchar(1000);
        lastRevision    number;
    begin
        v_sql := 'select max(OBJECT_INSTANCE_REVISION) from ' || tableName || ' where ' || byField || ' = ' || fieldValue;
        execute immediate v_sql into lastRevision;
        return lastRevision;
    end;


    -- Процедура виявляє різницю в записах двох ревізій
    -- і додає запис різниці в таблицю CORE_VER__REVISION_DIFFERENCE
    -- Аргументи:
    --  @ table_name    - ім'я таблиці для пошуку записів
    --  @ item_id   -   ідентифікатор об'єкту пошуку
    --  @ prev_rev_num  - номер попередньої ревізії
    --  @ cur_rev_num   - Номер поточної ревізії   
    procedure StoreRevisionDiff (
        tableName           in  varchar,
        objInstanceId       in  raw,
        objInstanceRev      in  number      
    )
    as
        prevRevRecord varchar2(2000);
        curRevRecord  varchar2(2000);        
        compareScript       clob;        
        revDiff             clob;
        v_sql               clob;       
        ctx DBMS_MLE.context_handle_t := DBMS_MLE.create_context();         
    
    begin
        execute immediate 'select json_arrayagg (json_object (*) returning varchar2) from ' || tableName || 
            ' where OBJECT_INSTANCE_ID = :1 and OBJECT_INSTANCE_REVISION=:2' into prevRevRecord using objInstanceId, objInstanceRev-1;
        execute immediate 'select json_arrayagg (json_object (*) returning varchar2) from ' || tableName || 
            ' where OBJECT_INSTANCE_ID = :1 and OBJECT_INSTANCE_REVISION=:2' into curRevRecord using objInstanceId, objInstanceRev;        

        dbms_mle.export_to_mle(ctx, 'prevRevStr', prevRevRecord);
        dbms_mle.export_to_mle(ctx, 'curRevStr', curRevRecord);
    
        compareScript := q'~ 
            try {
                let bindings = require('mle-js-bindings');
                let diff = "[";                             
                let prevRevJSON = JSON.parse(bindings.importValue("prevRevStr"))[0];
                let curRevJSON = JSON.parse(bindings.importValue("curRevStr"))[0];                
            
                // Exclude versioning specific fields
                let exceptionFieldsList = [
                    'ID',
                    'OBJECT_INSTANCE_REVISION',
                    'OBJECT_INSTANCE_REVISION_CREATED_WITH',
                    'OBJECT_INSTANCE_REVISION_CREATED_AT',
                    'OBJECT_INSTANCE_REVISION_INVALIDATED_WITH',
                    'OBJECT_INSTANCE_REVISION_INVALIDATED_AT',
                    'OBJECT_INSTANCE_REVISION_INVALIDATION_REASON',
                ];

                for (prop in curRevJSON){
                    if (!exceptionFieldsList.includes(prop) && prevRevJSON[prop] != curRevJSON[prop]){
                        diff += `${prop}: {'prevRevision': ${prevRevJSON[prop]}, 'curRevision': ${curRevJSON[prop]}}, `;                                   
                    }
                }
                diff += "]";
                bindings.exportValue("revDiff", diff);          
            }
            catch (error){
                console.log(error);
            } ~';
    
        DBMS_MLE.eval(ctx, 'JAVASCRIPT', compareScript);
        dbms_mle.import_from_mle(ctx,'revDiff', revDiff);        
        INSERT INTO CORE_VER__REVISION_DIFFERENCE (OBJECT_ID, OBJECT_INSTANCE_REVISION, DIFF, TABLE_NAME)
            VALUES (objInstanceId, objInstanceRev, revDiff, tableName);          
        DBMS_MLE.drop_context(ctx); 
    end;


    -- Процедура неверсіонованого/версіонованого додавання, зміни і видалення даних
    -- Аргументи:
    --  @   crudAction - ознака дії: C - створення (INSERT)
    --                               U - модифікація (UPDATE)
    --                               D - видалення (DELETE)
    --  @   tableName - ім'я таблиці
    --  @   modelID   - ідентифікатор моделі
    --  @   objData   - дані для додавання/зміни/видалення у форматі JSON
    --  @   revCreationTimestamp - відмітка часу створення ревізії (у випадку версіонування). Якщо фргумент не
    --      переданий у процедуру (NULL), значення за замовчуванням - поточні дата/час.
    --      Формат 'YYYY-MM-DD HH24:MI:SS'
    --  @   revInvalidationTimestamp - відмітка часу інвалідації (закриття) ревізії (у випадку версіонування).
    --      Якщо фргумент не переданий у процедуру (NULL), значення за замовчуванням - поточні дата/час.
    --      Формат 'YYYY-MM-DD HH24:MI:SS'
    procedure StoreObjectWithVersioning (
        crudAction      in  varchar,
        tableName       in  varchar,
        modelID         in  raw,        
        taskID          in  raw default null,
        revInvalReason  in  raw default null,
        objData         in  clob,        
        revCreationTS   in  timestamp default null,
        revInvalTS      in  timestamp default null
    ) as
        jsonRec         clob := json_query(objData, '$[0]');
        jsonRec_t       json_object_t := json_object_t.parse(jsonRec);
        jsonRecUp_t     json_object_t; 
        v_sql           clob;
        revCT           varchar(19) := revCreationTS;
        revIT           varchar(19) := revInvalTS;
        cdsqId          varchar(36);
        cdqId           varchar(36);
        lastRevision    number;
        versioningFlag  number;    
    
    begin
        versioningFlag := GetTableVersioningFlag(modelID, tableName);        

        if revCT is null then
            revCT := PKG_CORE_COMMON.GetCharCTS;        
        end if;

        if revIT is null then
            revIT := PKG_CORE_COMMON.GetCharCTS;        
        end if;

        cdsqId := replace(jsonRec_t.get('OBJECT_INSTANCE_ID').to_string,'"','''');
        cdqId := replace(jsonRec_t.get('OBJECT_INSTANCE_ID').to_string,'"','');
       
       -- Версіоноване/неверсіоноване додавання (INSERT)                                
       if crudAction = 'C' then
        if versioningFlag = 0 then
            v_sql := PKG_CORE_COMMON.GetInsertSQLFromJson(tableName, jsonRec);
            execute immediate v_sql;
        elsif versioningFlag = 1 then            
            jsonRec_t.put('OBJECT_INSTANCE_REVISION_CREATED_AT', 'TIMESTAMP ' || revCT);
            jsonRec_t.put('OBJECT_INSTANCE_REVISION', 0);
            jsonRec_t.put('OBJECT_INSTANCE_REVISION_CREATED_WITH', taskId);
            v_sql := PKG_CORE_COMMON.GetInsertSQLFromJson(tableName, jsonRec_t.to_clob());            
            execute immediate v_sql;
        end if;
       
       -- Версіоноване/неверсіоноване оновлення (UPDATE)
       elsif crudAction = 'U' then
        if versioningFlag = 0 then
            v_sql := PKG_CORE_COMMON.GetUpdateSQLFromJson(tableName, jsonRec_t.to_clob());
            -- [TBD] Add filters to GetUpdateSQLFromJson
            v_sql := v_sql || ' where ID=' || cdsqId;
            execute immediate v_sql;
        elsif versioningFlag = 1 then
            lastRevision := GetLastRevision(tableName, 'OBJECT_INSTANCE_ID', cdsqId);
            jsonRec_t.put('OBJECT_INSTANCE_REVISION_CREATED_AT', 'TIMESTAMP ' || revCT);
            jsonRec_t.put('OBJECT_INSTANCE_REVISION', lastRevision+1);
            jsonRec_t.put('OBJECT_INSTANCE_REVISION_CREATED_WITH', taskId);
            v_sql := PKG_CORE_COMMON.GetInsertSQLFromJson(tableName, jsonRec_t.to_clob());
            execute immediate v_sql;            
            InvalidateRevision(tableName, cdqId, lastRevision); -- [TBD] add TaskId, invalidationReason
            StoreRevisionDiff(tableName, cdqId, lastRevision+1);
        end if;

       -- Версіоноване/неверсіоноване видалення (DELETE)
       elsif crudAction = 'D' then
        if versioningFlag = 0 then
            v_sql := 'delete from ' || tableName || ' where ID = ' || cdsqId;
        elsif versioningFlag = 1 then            
            InvalidateRevision(tableName, cdqId, lastRevision); -- [TBD] add TaskId, invalidationReason
        end if;
       end if;
    end;

    
    -- Процедура здійснює закриття (інвалідацію) ревізії об'єкта
    --  шляхом встановлення ненульового (not null) значення поля OBJECT_INSTANCE_REVISION_INVALIDATED_AT,
    --  а також зазначення причини інвалідації та ідентифікатору задачі, що інвалідує ревізію.
    -- АРГУМЕНТИ:
    --  @   tableName               -   назва таблиці
    --  @   objectInstanceId        -   ідентифікатор екземпляра об'єкта
    --  @   revisionNumber          -   номер ревізії, яка підлягає інвалідації
    --  @   taskId                  -   задача, що інвалідує ревізію
    --  @   invalidationReason      -   ідентифікатор причини інвалідації
    --  @   invalidationTimestamp   -   мітка часу інвалідації ревізії
    procedure InvalidateRevision (
        tableName               in varchar,
        objInstanceId           in raw,
        revisionNumber          in number,
        taskId                  in raw default null,
        invalidationReason      in raw default null,
        invalidationTimestamp   in timestamp default null
    )
    as
        revInvTS varchar(19) := invalidationTimestamp;
        v_sql varchar(1000);
    begin
       if revInvTS is null then
        revInvTS := PKG_CORE_COMMON.GetCharCTS;
       end if;       
        v_sql := 'UPDATE ' || tableName || ' SET
                    OBJECT_INSTANCE_REVISION_INVALIDATED_AT = TIMESTAMP ''' || revInvTS || ''',
                    OBJECT_INSTANCE_REVISION_INVALIDATION_REASON = ''' || invalidationReason || ''',
                    OBJECT_INSTANCE_REVISION_INVALIDATED_WITH = ''' || taskId || '''
                    WHERE OBJECT_INSTANCE_ID = ''' || objInstanceId ||
                    ''' AND OBJECT_INSTANCE_REVISION = ' || revisionNumber;
        execute immediate v_sql;
    end;

    -- Функція повертає ланцюжок ревізій компонентів екземпляра об'єкту, активних на
    -- вказаний час у форматі {"<Таблиця>":"<ID запису ревізії>"}
    -- АРГУМЕНТИ:    
    --  @   objectInstanceId    -   ідентифікатор екземпляра об'єкта
    --  @   timePoint           -   мітка часу   
    function GetObjectInstanceRevisionChain (      
      objInstanceId   raw,
      timePoint       varchar
    ) return          clob
    as      
      tableList       varchar(2000);            
      v_sql           clob;
      recId           raw(16);
      l_vc_tables     APEX_APPLICATION_GLOBAL.VC_ARR2;
      jsonRec_t       json_object_t := json_object_t();

      -- timeStampLimit - використовується коли поле 
      --  OBJECT_INSTANCE_REVISION_INVALIDATED_AT = NULL
      timeStampLimit  varchar(20) := '2100-01-01 00:00:00';
      -- Виключення, що виникає коли поле OBJECT_INSTANCE_REVISION_INVALIDATED_AT
      --  відсутнє у таблиці, тобто таблиця не є версіонованою ("versioning": false)
      columnExistsException exception;      
      pragma exception_init(columnExistsException , -00904);
      
    begin      
      tableList := PKG_CORE_COMMON.GetObjectComponentTables(
        PKG_CORE_COMMON.GetObjectIdByInstance(objInstanceId)
      );
      l_vc_tables := APEX_STRING.STRING_TO_TABLE(tableList, ',');      

      for i in 1..l_vc_tables.count loop
        v_sql := 'SELECT ID FROM "' || l_vc_tables(i) || '" 
          WHERE OBJECT_INSTANCE_ID = ''' || objInstanceId || ''' 
          AND TIMESTAMP ''' || timePoint || ''' BETWEEN "OBJECT_INSTANCE_REVISION_CREATED_AT"
          AND nvl("OBJECT_INSTANCE_REVISION_INVALIDATED_AT", TIMESTAMP ''' || timeStampLimit || ''')';       
        begin
          execute immediate v_sql into recId;    
            jsonRec_t.put(l_vc_tables(i), recId);          
          exception when columnExistsException then null;        
        end;    
      end loop;
      return jsonRec_t.to_clob;      
    end;

end "PKG_CORE_VERSIONING";
/