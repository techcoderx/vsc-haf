-- Create HAF tables here
CREATE TABLE IF NOT EXISTS vsc_app.table_name(
    hive_rowid BIGINT NOT NULL DEFAULT nextval('hive.vsc_app_hive_rowid_seq'), -- registered tables must have this field
    id SERIAL PRIMARY KEY,
    username VARCHAR
)

CREATE TABLE IF NOT EXISTS vsc_app.state(
    id SERIAL PRIMARY KEY,
    last_processed_block INTEGER NOT NULL DEFAULT 0,
    db_version INTEGER NOT NULL DEFAULT 1
);