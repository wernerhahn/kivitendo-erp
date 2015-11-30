-- @tag: shop_orders_2
-- @description: Hinzufügen der Spalte Position in der Tabelle shop_order_items
-- @depends: release_3_3_0
ALTER TABLE shop_order_items ADD COLUMN position integer;
