-- @tag: shops
-- @description: Tabelle für Shops
-- @depends: release_3_3_0
-- @ignore: 0

CREATE TABLE shops (
  id SERIAL PRIMARY KEY,
  description text,
  obsolete BOOLEAN NOT NULL DEFAULT false,
  sortkey INTEGER,
  connector text,     -- hardcoded options, e.g. xtcommerce, shopware
  pricetype text,     -- netto/brutto
  price_source text,  -- sellprice/listprice/lastcost or pricegroup id
  url text,
  port INTEGER,
  login text,  -- "user" is reserved
  password text
);
