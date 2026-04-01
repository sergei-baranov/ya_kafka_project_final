CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS goods_filtered (
  product_id VARCHAR(512) PRIMARY KEY,
  product_data JSONB,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_goods_filtered_product_data_name_trgm ON goods_filtered 
USING GIN ((product_data ->> 'name') gin_trgm_ops);

/*
SELECT
  product_id as product_id,
  product_data ->> 'name' as product_name
FROM
  goods_filtered
WHERE
  product_data ->> 'name' ILIKE '%phone%'
ORDER BY
  (product_data ->> 'name' ILIKE 'iphone%') DESC, -- TRUE (1) будет выше
  product_data ->> 'name' ASC
;
*/

CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_goods_filtered_updated_at
BEFORE UPDATE ON goods_filtered
FOR EACH ROW
EXECUTE FUNCTION update_modified_column();

CREATE TABLE IF NOT EXISTS client_api_search (
  client INT NOT NULL,
  word VARCHAR(512) NOT NULL,
  request_counter INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (client, word)
);

CREATE INDEX idx_client_api_search_word_client
ON client_api_search (word, client);

CREATE TRIGGER update_client_api_search_updated_at
BEFORE UPDATE ON client_api_search
FOR EACH ROW
EXECUTE FUNCTION update_modified_column();

/*
INSERT INTO goods_filtered (product_id, product_data)
VALUES ('123', '{"boo": "moo"}'::jsonb)
ON CONFLICT (product_id) 
DO UPDATE SET product_data = EXCLUDED.product_data
;
*/

/*
INSERT INTO client_api_search (client, word)
VALUES (123, "boo")
ON CONFLICT (client, word) 
DO UPDATE SET request_counter = request_counter + 1
;
*/

-- "signal.data.collection": "public.debezium_signal"
/*
CREATE TABLE IF NOT EXISTS debezium_signal (
  id VARCHAR(42) PRIMARY KEY,
  type VARCHAR(32) NOT NULL,
  data VARCHAR(2048) NULL
);
*/
