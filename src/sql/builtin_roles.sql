-- Role involved into data schema creation.
DO $$
BEGIN
  CREATE ROLE magi_owner WITH LOGIN INHERIT IN ROLE hive_applications_owner_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

DO $$
BEGIN
  CREATE ROLE magi_user WITH LOGIN INHERIT IN ROLE hive_applications_group;  
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

--- Allow to create schemas
GRANT magi_owner TO haf_admin;
GRANT magi_user TO magi_owner;