-- @tag: shops2
-- @description: Alter table shops more columns for configuration
-- @charset: UTF-8
-- @depends: release_3_4_0 shops
-- @ignore: 0

ALTER TABLE shops ADD COLUMN last_order_number integer;
ALTER TABLE shops ADD COLUMN orders_to_fetch integer;
