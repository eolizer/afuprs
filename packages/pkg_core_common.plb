create or replace package body "PKG_CORE_COMMON" as
    
    --  Функція визначає і повертає мітку поточного часу у визначеному форматі
    --  РЕЗУЛЬТАТ:
    --  Рядок поточної мітки час у форматі YYYY-MM-DD HH24:MI:SS
    function GetCharCTS
    return varchar
    as
        cts varchar(19);
    begin
        select to_char(systimestamp,'YYYY-MM-DD HH24:MI:SS') into cts from dual;
        return cts;
    end;
    
    --  Функція повертає ключи словника JSON
    --  АРГУМЕНТИ:
    --  @   jsonDict    - словник JSON
    function GetJsonKeys (
        jsonDict    in clob
    ) return json_array_t
    as
        v_json json_object_t;
        v_json_keys  json_key_list;
        ja  json_array_t;

    begin
        v_json := json_object_t.parse(jsonDict);
        v_json_keys := v_json.get_keys;
        ja := new json_array_t;
        
        for i in 1..v_json_keys.COUNT loop
            ja.append(v_json_keys(i));
        end loop;        
        return ja;
    end;

    --  Функція повертає лістинг команди INSERT, що базується на даних словника JSON
    --  АРГУМЕНТИ:
    --  @   tableName   - назва таблиці для вставки
    --  @   jsonRec     - словник JSON
    --  ПРИКЛАД:
    --  Виклик GetInsertSQLFromJson("tb_employee", {"name": "John", "surname": "doe", "age": 27}) поверне
    --   INSERT INTO "tb_employee" ("name", "surname", "age") VALUES ('John', 'Doe', '27')
    function GetInsertSQLFromJson (
        tableName   in  varchar,
        jsonRec in  clob
    ) return varchar
    as
        jsonRec_t json_object_t := json_object_t(jsonRec);
        json_keys json_array_t := PKG_CORE_COMMON.GetJsonKeys(jsonRec);
        v_sql clob;
        v_sql_vals clob;
        keyName varchar(255);
        keyListLength number;
        keyVal varchar(255);

    begin
        v_sql := 'INSERT INTO ' || dbms_assert.sql_object_name(dbms_assert.enquote_name(tableName, FALSE))
                || ' (';
        v_sql_vals := ') VALUES (';
        keyListLength := json_keys.get_size() - 1;         
        for pos in 0 .. keyListLength
            loop
                keyName := json_keys.get_string(pos);
                keyVal := replace(jsonRec_t.get(keyName).to_string,'"','');
                if keyVal != 'null' then   
                    v_sql := v_sql || dbms_assert.enquote_name(keyName, FALSE);
                    if upper(substr(keyVal,1,9)) = 'TIMESTAMP' then
                        keyVal := 'TIMESTAMP ' || '''' || upper(substr(keyVal, 11)) || '''' ;                        
                        v_sql_vals := v_sql_vals || keyVal;
                    else              
                        v_sql_vals := v_sql_vals || dbms_assert.enquote_literal(keyVal);
                    end if;                  
                    if pos < keyListLength then
                        v_sql := v_sql || ',';
                        v_sql_vals := v_sql_vals || ',';
                    end if;
                end if;                                              
            end loop;
            v_sql := v_sql || v_sql_vals || ')';        
        return v_sql;
    end;


    --  Функція повертає лістинг команди UPDATE, що базується на даних
    --  словника JSON
    --  АРГУМЕНТИ:
    --  @   tableName   - назва таблиці для вставки   
    --  @   jsonRec     - словник JSON
    --  ПРИКЛАД:
    --  Виклик GetInsertSQLFromJson("tb_employee", {"name": "John", "surname": "doe", "age": 27}) поверне
    --   UPDATE "tb_employee" SET "name" = 'John', "surname" = 'Doe', "age" = 27
    function GetUpdateSQLFromJson (
        tableName   in  varchar,
        jsonRec in  clob       
    ) return varchar
    as
        jsonRec_t json_object_t := json_object_t(jsonRec);
        json_keys json_array_t := PKG_CORE_COMMON.GetJsonKeys(jsonRec);
        v_sql clob;
        v_sql_vals clob;
        keyName varchar(255);
        keyListLength number;
        keyVal varchar(255);

    begin
        v_sql := 'update ' || tableName || ' set ';
        keyListLength := json_keys.get_size() - 1;
        for pos in 0 .. keyListLength
            loop
                keyName := json_keys.get_string(pos);
                keyVal := replace(jsonRec_t.get(keyName).to_string,'"','');
                if upper(substr(keyVal, 1, 9)) = 'TIMESTAMP' then
                    keyVal := 'TIMESTAMP ' || '''' || upper(substr(keyVal, 11)) || '''' ;
                    v_sql := v_sql || keyName || '=' || keyVal;
                else
                    v_sql := v_sql || keyName || '=' || dbms_assert.enquote_literal(keyVal);    
                end if;
                if pos < keyListLength then
                    v_sql := v_sql ||', ';
                end if; 
            end loop;
        return v_sql;        
    end;


    -- ================================================
    --                МОДЕЛІ І ОБ'ЄКТИ                  
    -- ================================================

    --  Функція реєструє новий екземпляр об'єкту, створеного
    --  згідно моделі (modelId) в таблиці CORE_OBM__OBJECT_INSTANCE_REGISTRY
    --  АРГУМЕНТИ:
    --  @   modelId     - ідентифікатор моделі, згідно якої створено екземпляр
    --  РЕЗУЛЬТАТ:
    --  @   instanceId  - ідентифікатор екземпляра
    function RegisterModelInstance (
        modelId raw
    ) return raw
    as
        instanceId raw(16);
    begin
        insert into CORE_OBM__OBJECT_INSTANCE_REGISTRY ("MODEL_ID") values (modelId) returning ID into instanceId;
        return instanceId;
    end;

    --  Функція повертає ідентифікатор моделі
    --  АРГУМЕНТИ:
    --  @   modelName   - ім'я моделі
    --  РЕЗУЛЬТАТА:
    --  @   modelId     - ідентифікатор моделі
    function GetObjectModelIdByName (
        modelName in varchar     
    ) return raw
    as
        modelId raw(16);
    begin
        select objms.ID
            into modelId
            from CORE_OBM__OBJECT_MODELS objms
            where objms.OBJECT_MODEL.name = modelName;
        return modelId;
    end;

    --  Функція реєструє новий екземпляр об'єкту
    --  АРГУМЕНТИ:
    --  @   objectlId           - ідентифікатор об'єкту
    --  РЕЗУЛЬТАТ:
    --  @   objectInstanceId    - ідентифікатор екземпляра об'єкта    
    function RegisterObjectInstance (
        objectId in raw
    ) return raw
    as
        objectInstanceId raw(16);
    begin
        insert into CORE_OBM__OBJECT_INSTANCE ("OBJECT_ID") values (objectId) returning ID into objectInstanceId;
        return objectInstanceId;
    end;

    --  Функція повертає ідентифікатор об'єкту за іменем
    --  Аргументи:
    --  @   objectName - ім'я моделі    --  
    --  Результат:
    --  @   objectId - ідентифікатор моделі
    function GetObjectIdByName (
        objectName in varchar
    ) return raw
    as
        objectId raw(16);
    begin
        select obj.ID
            into objectId
            from CORE_OBM__OBJECT obj
            where obj.NAME = objectName;
        return objectId;
    end;

    --  Функція повертає ідентифікатор об'єкту за ідентифікатором екземпляра
    --  Аргументи:
    --  @   objInstanceId - ідентифікатор екземпляра об'єкту
    --  Результат:
    --  @   objectId - ідентифікатор моделі
    function GetObjectIdByInstance (
      objInstanceId in raw
    ) return raw
    as
      objId raw(16);
    begin
      select OBJECT_ID into objId from CORE_OBM__OBJECT_INSTANCE where ID = objInstanceId;
      return objId;
    end;

    --  Функція повертає JSON словник - схему об'єкта
    --  АРГУМЕНТИ:
    --  @ objectID    - ідентифікатор об'єкта
    function GetObjectModelSchema (
        objectId    raw
    ) return clob
    as
        modelSchema clob;
    begin
        select objms.OBJECT_MODEL into modelSchema from CORE_OBM__OBJECT_MODELS objms where objms.ID = objectId;
        return modelSchema;
    end;

    --  Функція повертає список таблиць компонентів об'єкту
    --  АРГУМЕНТИ:
    --  @	objectID    - ідентифікатор об'єкта
    --  РЕЗУЛЬТАТ:
    --  @	tableList   - список таблиць у форматі ["TABLE_1","TABLE_2","TABLE_A"....,"TABLE_Z"]
    function GetObjectComponentTables(
       objectId     raw
    ) return        varchar2
    as
      tableList    varchar2(1000);
    begin        
      select json_query(
        GetObjectModelSchema(objectId),
        '$.components[*].table'
        with wrapper) into tableList from dual;
      tableList :=  regexp_replace(tableLIst, '[]\[\"]', '');
      return tableList;
    end;
    

end "PKG_CORE_COMMON";
/