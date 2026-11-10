-- Drop privacy-only tile tables AFTER hex_detail is live, backed up, and the client uses it.
-- Do not apply until that checklist is done. Restore those tables from the pre-drop D1 export.

DROP TABLE IF EXISTS coverage_tiles;
DROP TABLE IF EXISTS hex_facts;
