-- @tag: chart_pos_er
-- @description: pos_er Feld in Konten für die Position ind er Erfolgsrechnung
-- @depends: release_3_3_0
-- @encoding: utf-8

ALTER TABLE chart ADD COLUMN pos_er INTEGER;
