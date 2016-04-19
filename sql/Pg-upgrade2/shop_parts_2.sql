-- @tag: shop_parts_2
-- @description: Add tables for part information for shop
-- @charset: UTF-8
-- @depends: release_3_3_0 shops
-- @ignore: 0
ALTER TABLE shop_parts ALTER COLUMN shop_category TYPE TEXT[] USING array[shop_category];
