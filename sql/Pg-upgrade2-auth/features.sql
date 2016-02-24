-- @tag: features
-- @description: flags to switch on/off the features for the clients
-- @depends: release_3_2_0

CREATE TABLE auth.feature (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  description TEXT
);

INSERT INTO auth.feature (name, description) VALUES
( 'datev', 'Anbindung zur Datenverarbeitung' ),
( 'ustva', 'Umsatzsteuer-Voranmeldung' ),
( 'eur'  , 'Betriebswirtschaftliche Auswertung, Gewinn- und Verlustrechnung' ),
( 'bilanz', 'summarische Gegenüberstellung' ),
( 'erfolgsrechnung', 'mehrstufige Gewinn- und Verlustrechnung' );

CREATE TABLE auth.clients_features (
  client_id       INTEGER NOT NULL REFERENCES auth.clients (id) ON DELETE CASCADE,
  feature_id      INTEGER NOT NULL REFERENCES auth.feature (id) ON DELETE RESTRICT,
  PRIMARY KEY     (client_id, feature_id)
);

INSERT INTO auth.clients_features (client_id, feature_id)
SELECT c.id, f.id FROM auth.clients AS c, auth.feature AS f WHERE f.name != 'erfolgsrechnung' ORDER BY c.id, f.id;
