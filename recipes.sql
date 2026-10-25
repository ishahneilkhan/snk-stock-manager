-- Restaurant module: dishes with recipes. Run after schema.sql and logic.sql.
-- Ingredients are ordinary products (e.g. rice in grams) with batches and stock.
-- Selling a dish takes its ingredients out of stock through the same FEFO ledger.

CREATE TABLE dishes (
  id      bigserial PRIMARY KEY,
  shop_id bigint NOT NULL REFERENCES shops(id),
  name    text NOT NULL,
  price   numeric(14,2) NOT NULL CHECK (price >= 0),
  active  boolean NOT NULL DEFAULT true,
  UNIQUE (shop_id, name)
);
CREATE TABLE recipe_items (
  dish_id    bigint NOT NULL REFERENCES dishes(id) ON DELETE CASCADE,
  product_id bigint NOT NULL REFERENCES products(id),
  qty        numeric(14,3) NOT NULL CHECK (qty > 0),     -- base units per ONE dish (grams, ml, pieces)
  PRIMARY KEY (dish_id, product_id)
);
-- What each dish line cost at the time of sale (so old profit figures never change)
CREATE TABLE sale_dish_items (
  id         bigserial PRIMARY KEY,
  sale_id    bigint NOT NULL REFERENCES sales(id),
  dish_id    bigint NOT NULL REFERENCES dishes(id),
  qty        numeric(14,3) NOT NULL CHECK (qty > 0),
  unit_price numeric(14,2) NOT NULL,
  unit_cost  numeric(14,4) NOT NULL
);
ALTER TABLE sales
  ADD COLUMN IF NOT EXISTS order_type text CHECK (order_type IN ('dine','take','delivery')),
  ADD COLUMN IF NOT EXISTS table_no   text;

-- Current cost per base unit of each ingredient: weighted average of batches still in stock,
-- or the latest batch cost when nothing is in stock.
CREATE VIEW ingredient_cost AS
  SELECT b.product_id,
         COALESCE(SUM(b.cost_price * s.qty) FILTER (WHERE s.qty > 0)
                  / NULLIF(SUM(s.qty) FILTER (WHERE s.qty > 0), 0),
                  (array_agg(b.cost_price ORDER BY b.received_at DESC, b.id DESC))[1]) AS cost_per_unit
  FROM batches b LEFT JOIN batch_stock s ON s.batch_id = b.id
  GROUP BY b.product_id;

CREATE VIEW dish_margin AS
  SELECT d.id AS dish_id, d.shop_id, d.name, d.price,
         COALESCE(SUM(ri.qty * ic.cost_per_unit), 0) AS cost,
         d.price - COALESCE(SUM(ri.qty * ic.cost_per_unit), 0) AS profit
  FROM dishes d
  LEFT JOIN recipe_items ri ON ri.dish_id = d.id
  LEFT JOIN ingredient_cost ic ON ic.product_id = ri.product_id
  GROUP BY d.id;

-- p_items example: [{"product_id": 10, "qty": 150}, {"product_id": 11, "qty": 200}]
-- Replaces the whole recipe. Owner only. Past sales keep their recorded cost.
CREATE FUNCTION set_recipe(p_shop bigint, p_user bigint, p_dish bigint, p_items jsonb)
RETURNS void AS $$
BEGIN
  PERFORM assert_user(p_shop, p_user, true);
  IF NOT EXISTS (SELECT 1 FROM dishes WHERE id = p_dish AND shop_id = p_shop) THEN
    RAISE EXCEPTION 'dish not found';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'a recipe needs at least one ingredient'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_items) AS x(product_id bigint, qty numeric)
             LEFT JOIN products p ON p.id = x.product_id AND p.shop_id = p_shop
             WHERE p.id IS NULL OR x.qty IS NULL OR x.qty <= 0) THEN
    RAISE EXCEPTION 'unknown ingredient or bad quantity';
  END IF;
  DELETE FROM recipe_items WHERE dish_id = p_dish;
  INSERT INTO recipe_items (dish_id, product_id, qty)
  SELECT p_dish, x.product_id, SUM(x.qty)
    FROM jsonb_to_recordset(p_items) AS x(product_id bigint, qty numeric) GROUP BY x.product_id;
  INSERT INTO audit_log (shop_id, user_id, action, table_name, row_id, new_data)
  VALUES (p_shop, p_user, 'set_recipe', 'dishes', p_dish, p_items);
END $$ LANGUAGE plpgsql;

-- ORDER ----------------------------------------------------------------
-- p_items example: [{"dish_id": 1, "qty": 3}]. Prices come from the dishes table, not the client.
-- Ingredients are taken from stock with FEFO. Not enough of an ingredient = the order fails
-- (strict). If your kitchen's stock counts are rough, relax this later on purpose.
CREATE FUNCTION create_dish_sale(p_shop bigint, p_user bigint, p_client_uuid uuid, p_order_type text,
                                 p_table_no text, p_customer bigint, p_method text,
                                 p_discount numeric, p_paid numeric, p_items jsonb)
RETURNS bigint AS $$
DECLARE
  v_role text; v_sale bigint; v_costs jsonb := '{}'; v_sub numeric := 0; v_total numeric;
  v_paid numeric; v_cost numeric; ing record; f record; d record;
BEGIN
  v_role := assert_user(p_shop, p_user);
  SELECT id INTO v_sale FROM sales WHERE client_uuid = p_client_uuid;
  IF FOUND THEN RETURN v_sale; END IF;

  IF COALESCE(p_discount, 0) < 0 THEN RAISE EXCEPTION 'discount cannot be negative'; END IF;
  IF COALESCE(p_discount, 0) > 0 AND v_role <> 'owner' THEN RAISE EXCEPTION 'only the owner can give a discount'; END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'no items'; END IF;
  IF p_customer IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM customers WHERE id = p_customer AND shop_id = p_shop) THEN
    RAISE EXCEPTION 'customer not found';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_items) AS x(dish_id bigint, qty numeric)
             LEFT JOIN dishes dd ON dd.id = x.dish_id AND dd.shop_id = p_shop AND dd.active
             WHERE dd.id IS NULL OR x.qty IS NULL OR x.qty <= 0) THEN
    RAISE EXCEPTION 'unknown dish or bad quantity';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_items) AS x(dish_id bigint, qty numeric)
             WHERE NOT EXISTS (SELECT 1 FROM recipe_items ri WHERE ri.dish_id = x.dish_id)) THEN
    RAISE EXCEPTION 'a dish in this order has no recipe';
  END IF;

  INSERT INTO sales (shop_id, client_uuid, customer_id, discount, total, paid, payment_method,
                     created_by, order_type, table_no)
  VALUES (p_shop, p_client_uuid, p_customer, COALESCE(p_discount, 0), 0, 0, p_method,
          p_user, p_order_type, p_table_no)
  RETURNING id INTO v_sale;

  -- one pass per ingredient, in product order (no deadlocks between simultaneous orders)
  FOR ing IN
    SELECT ri.product_id, SUM(ri.qty * x.qty) AS need
    FROM jsonb_to_recordset(p_items) AS x(dish_id bigint, qty numeric)
    JOIN recipe_items ri ON ri.dish_id = x.dish_id
    GROUP BY ri.product_id ORDER BY ri.product_id
  LOOP
    SELECT * INTO f FROM sell_fefo(v_sale, ing.product_id, ing.need, p_user);
    v_costs := v_costs || jsonb_build_object(ing.product_id::text, f.o_cost / ing.need);
  END LOOP;

  FOR d IN
    SELECT x.dish_id, SUM(x.qty) AS qty, dd.price
    FROM jsonb_to_recordset(p_items) AS x(dish_id bigint, qty numeric)
    JOIN dishes dd ON dd.id = x.dish_id
    GROUP BY x.dish_id, dd.price ORDER BY x.dish_id
  LOOP
    SELECT SUM(ri.qty * (v_costs ->> ri.product_id::text)::numeric) INTO v_cost
      FROM recipe_items ri WHERE ri.dish_id = d.dish_id;
    INSERT INTO sale_dish_items (sale_id, dish_id, qty, unit_price, unit_cost)
    VALUES (v_sale, d.dish_id, d.qty, d.price, v_cost);
    v_sub := v_sub + d.qty * d.price;
  END LOOP;

  v_total := round(v_sub - COALESCE(p_discount, 0), 2);
  IF v_total < 0 THEN RAISE EXCEPTION 'discount is more than the bill'; END IF;
  v_paid := CASE WHEN p_method = 'due' THEN LEAST(COALESCE(p_paid, 0), v_total) ELSE v_total END;
  UPDATE sales SET total = v_total, paid = v_paid WHERE id = v_sale;
  RETURN v_sale;
END $$ LANGUAGE plpgsql;
