--
-- This is a Media Cloud PostgreSQL schema difference file (a "diff") between schema
-- versions 4558 and 4559.
--
-- If you are running Media Cloud with a database that was set up with a schema version
-- 4558, and you would like to upgrade both the Media Cloud and the
-- database to be at version 4559, import this SQL file:
--
--     psql mediacloud < mediawords-4558-4559.sql
--
-- You might need to import some additional schema diff files to reach the desired version.
--

--
-- 1 of 2. Import the output of 'apgdiff':
--

SET search_path = public, pg_catalog;


--
-- Stories from failed Bit.ly RabbitMQ queue
-- (RabbitMQ failed reindexing a huge queue so we had to recover stories in
-- that queue manually. Story IDs from this table are to be gradually moved to
-- Bit.ly processing schedule.)
--
CREATE TABLE IF NOT EXISTS stories_from_failed_bitly_rabbitmq_queue (
    stories_id BIGINT NOT NULL REFERENCES stories (stories_id)
);
CREATE INDEX stories_from_failed_bitly_rabbitmq_queue_stories_id
    ON stories_from_failed_bitly_rabbitmq_queue (stories_id);


CREATE OR REPLACE FUNCTION set_database_schema_version() RETURNS boolean AS $$
DECLARE

    -- Database schema version number (same as a SVN revision number)
    -- Increase it by 1 if you make major database schema changes.
    MEDIACLOUD_DATABASE_SCHEMA_VERSION CONSTANT INT := 4559;

BEGIN

    -- Update / set database schema version
    DELETE FROM database_variables WHERE name = 'database-schema-version';
    INSERT INTO database_variables (name, value) VALUES ('database-schema-version', MEDIACLOUD_DATABASE_SCHEMA_VERSION::int);

    return true;

END;
$$
LANGUAGE 'plpgsql';

--
-- 2 of 2. Reset the database version.
--
SELECT set_database_schema_version();
