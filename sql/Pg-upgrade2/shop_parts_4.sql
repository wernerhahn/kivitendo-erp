-- @tag: shop_parts_4
-- @description: Add tables for part information for shop
-- @charset: UTF-8
-- @depends: release_3_3_0 shops
-- @ignore: 0
ALTER TABLE shop_parts ADD COLUMN active_price_source text;
ALTER TABLE shop_parts ADD COLUMN metatag_keywords text;
ALTER TABLE shop_parts ADD COLUMN metatag_description text;
ALTER TABLE shop_parts ADD COLUMN metatag_title text;
ALTER TABLE shop_parts DROP COLUMN meta_tags;
