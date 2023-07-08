# TypeScript HAF App Template

[VSC](https://github.com/vsc-eco/vsc-node) HAF indexer and API server. Indexes Hive from the VSC genesis block number for the relevant VSC operations using the HAF app sync algorithm.

## Required Dependencies

* `nodejs` and `npm` (Latest LTS, v18 minimum supported)
* Synced [HAF](https://gitlab.syncad.com/hive/haf) node

## Setup

### PostgreSQL Roles
```pgsql
CREATE ROLE vsc_app WITH LOGIN PASSWORD 'vscpass' CREATEROLE INHERIT IN ROLE hive_applications_group;
CREATE ROLE vsc_user WITH LOGIN INHERIT IN ROLE hive_applications_group;
GRANT CREATE ON DATABASE block_log TO vsc_app;
GRANT vsc_user TO vsc_app;
```

### PostgREST Installation
```bash
./scripts/postgrest_install.sh
```

### PostgREST API methods
```bash
psql -f src/sql/create_apis.sql block_log
```

## Sync
```bash
npm start
```

## Start PostgREST server
```bash
./scripts/postgrest_start.sh postgres://vsc_app:<vsc_app_password>@localhost:5432/block_log <server_port>
```

## Start Express server
```bash
npm run server
```
