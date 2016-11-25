ALTER TABLE file MODIFY COLUMN lane_id INT(10) NOT NULL DEFAULT 0;
ALTER TABLE lane MODIFY COLUMN lane_id INT(10) NOT NULL DEFAULT 0;
ALTER TABLE lane MODIFY COLUMN library_id INT(10) NOT NULL DEFAULT 0;
ALTER TABLE library MODIFY COLUMN sample_id INT(10) NOT NULL DEFAULT 0;
ALTER TABLE sample MODIFY COLUMN sample_id INT(10) NOT NULL DEFAULT 0;
ALTER TABLE species MODIFY COLUMN taxon_id MEDIUMINT(8) NOT NULL DEFAULT 0;
ALTER TABLE seq_request MODIFY COLUMN library_id INT(10) NOT NULL DEFAULT 0;
ALTER TABLE mapstats MODIFY COLUMN lane_id INT(10) NOT NULL DEFAULT 0;
ALTER TABLE library_request MODIFY COLUMN sample_id INT(10) NOT NULL DEFAULT 0;
update schema_version set schema_version=30;