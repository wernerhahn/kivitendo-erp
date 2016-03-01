-- @tag: files
-- @description: Tabelle für Files
-- @charset: UTF-8
-- @depends: release_3_3_0
-- @ignore: 0

CREATE TABLE files(
  id                          SERIAL PRIMARY KEY,
  modul                       TEXT NOT NULL, -- Tabellenname des Moduls z.B. customer, parts ... Fremdschlüssel Zusammen mit trans_id
  trans_id                    INTEGER NOT NULL, -- Fremschlüssel auf die id der Tabelle aus Spalte modul
  filename                    TEXT NOT NULL, -- Dateiname
  location                    TEXT, -- Dateipfad
  description                 TEXT, -- Zusätzliche Beschreibung z.B. Alternative Bildbeschreibung für Shopbilder
  position                    INTEGER , -- Sortierreihenfolge der Bilder UNIQUE zusammen mit trans_id
  itime                       TIMESTAMP DEFAULT now(),
  mtime                       TIMESTAMP,
  file_content                bytea,
  files_img_width             integer,
  files_img_height            integer,
  thumbnail_img_content       bytea,
  thumbnail_img_width         integer,
  thumbnail_img_height        integer,
  title                       varchar(45),
  file_content_type           TEXT,
  files_mtime                 TIMESTAMP DEFAULT now(),
  thumbnail_img_content_type  TEXT
);

CREATE TRIGGER mtime_files BEFORE UPDATE ON files
    FOR EACH ROW EXECUTE PROCEDURE set_mtime();
