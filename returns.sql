-- Sale returns. Run after schema.sql and logic.sql (and sync.sql if you use it).

CREATE TABLE sale_returns (
  id            bigserial PRIMARY KEY,
  shop_id       bigint NOT NULL REFERENCES shops(id),
  sale_id       bigint NOT NULL REFERENCES sales(id),
  client_uuid   uuid NOT NULL UNIQUE,             -- a retry never returns twice
  reason        text NOT NULL,
  restock       boolean NOT NULL,                 -- false = goods are NOT put back on the shelf
  refund_total  numeric(14,2) NOT NULL DEFAULT 0,
  refund_to_due numeric(14,2) NOT NULL DEFAULT 0, -- reduces what the customer still owes
  refund_cash   numeric(14,2) NOT NULL DEFAULT 0, -- money handed back
  created_by    bigint NOT NULL REFERENCES users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (refund_to_due + refund_cash = refund_total)
);
CREATE TABLE sale_return_items (
  id         bigserial PRIMARY KEY,
  return_id  bigint NOT NULL REFERENCES sale_returns(id),
  product_id bigint NOT NULL REFERENCES products(id),
  qty        numeric(14,3) NOT NULL CHECK (qty > 0),   -- base units
  unit_price numeric(14,4) NOT NULL,
  unit_cost  numeric(14,4) NOT NULL
);

-- A return that reduces a customer's due must also show up in the balance.
CREATE OR REPLACE VIEW customer_balance AS
  SELECT c.id AS customer_id, c.shop_id, c.name,
         COALESCE((SELECT SUM(total - paid) FROM sales WHERE customer_id = c.id), 0)
       - COALESCE((SELECT SUM(amount) FROM payments
                   WHERE party_type = 'customer' AND party_id = c.id), 0)
       - COALESCE((SELECT SUM(sr.refund_to_due) FROM sale_returns sr
                   JOIN sales s ON s.id = sr.sale_id WHERE s.customer_id = c.id), 0) AS due
  FROM customers c;

-- p_items example: [{"product_id": 1, "qty": 5}]   (qty in base units)
-- p_restock: true puts the goods back into the batches they came from (via the stock ledger).
-- For medicines you will often want false (returned medicine is not resold); the owner decides.
-- Owner only. Refund = quantity x the price actually charged on that bill (discount shared out).
CREATE FUNCTION create_sale_return(p_shop bigint, p_user bigint, p_client_uuid uuid, p_sale bigint,
                                   p_items jsonb, p_restock boolean, p_reason text)
RETURNS bigint AS $$
DECLARE
  v_ret bigint; sl record; it record; m record;
  v_sold numeric; v_done numeric; v_price numeric; v_cost numeric;
  v_amount numeric := 0; v_ratio numeric; v_due numeric; v_to_due numeric := 0;
  v_left numeric; v_take numeric;
BEGIN
  PERFORM assert_user(p_shop, p_user, true);
  SELECT id INTO v_ret FROM sale_returns WHERE client_uuid = p_client_uuid;
  IF FOUND THEN RETURN v_ret; END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a reason is required'; END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'no items'; END IF;
  SELECT id, customer_id, total, discount INTO sl FROM sales WHERE id = p_sale AND shop_id = p_shop;
  IF NOT FOUND THEN RAISE EXCEPTION 'sale not found'; END IF;
  v_ratio := CASE WHEN sl.total + sl.discount > 0 THEN sl.total / (sl.total + sl.discount) ELSE 1 END;

  INSERT INTO sale_returns (shop_id, sale_id, client_uuid, reason, restock, created_by)
  VALUES (p_shop, p_sale, p_client_uuid, p_reason, COALESCE(p_restock, false), p_user)
  RETURNING id INTO v_ret;

  FOR it IN
    SELECT x.product_id, SUM(x.qty) AS qty
    FROM jsonb_to_recordset(p_items) AS x(product_id bigint, qty numeric)
    GROUP BY x.product_id ORDER BY x.product_id
  LOOP
    IF it.qty IS NULL OR it.qty <= 0 THEN RAISE EXCEPTION 'quantity must be positive'; END IF;
    SELECT SUM(qty), SUM(qty * unit_price) / SUM(qty), SUM(qty * unit_cost) / SUM(qty)
      INTO v_sold, v_price, v_cost
      FROM sale_items WHERE sale_id = p_sale AND product_id = it.product_id;
    IF v_sold IS NULL THEN RAISE EXCEPTION 'product % is not in this sale', it.product_id; END IF;
    SELECT COALESCE(SUM(i.qty), 0) INTO v_done
      FROM sale_return_items i JOIN sale_returns r ON r.id = i.return_id
     WHERE r.sale_id = p_sale AND i.product_id = it.product_id AND r.id <> v_ret;
    IF it.qty > v_sold - v_done THEN
      RAISE EXCEPTION 'return is more than sold (product %)', it.product_id;
    END IF;

    INSERT INTO sale_return_items (return_id, product_id, qty, unit_price, unit_cost)
    VALUES (v_ret, it.product_id, it.qty, v_price, v_cost);
    v_amount := v_amount + it.qty * v_price * v_ratio;

    IF p_restock THEN
      v_left := it.qty;
      FOR m IN
        SELECT batch_id, -SUM(qty) AS sold FROM stock_movements
         WHERE ref_type = 'sale' AND ref_id = p_sale AND product_id = it.product_id AND kind = 'sale'
         GROUP BY batch_id ORDER BY batch_id
      LOOP
        EXIT WHEN v_left <= 0;
        v_take := LEAST(v_left, m.sold - COALESCE((
            SELECT SUM(sm.qty) FROM stock_movements sm JOIN sale_returns r ON r.id = sm.ref_id
             WHERE sm.ref_type = 'sale_return' AND r.sale_id = p_sale AND sm.batch_id = m.batch_id), 0));
        CONTINUE WHEN v_take <= 0;
        INSERT INTO stock_movements (shop_id, product_id, batch_id, qty, kind, ref_type, ref_id, reason, user_id)
        VALUES (p_shop, it.product_id, m.batch_id, v_take, 'sale_return', 'sale_return', v_ret, p_reason, p_user);
        v_left := v_left - v_take;
      END LOOP;
      IF v_left > 0 THEN RAISE EXCEPTION 'cannot put back more than was taken from the batches'; END IF;
    END IF;
  END LOOP;

  v_amount := round(v_amount, 2);
  IF sl.customer_id IS NOT NULL THEN
    SELECT due INTO v_due FROM customer_balance WHERE customer_id = sl.customer_id;
    v_to_due := LEAST(v_amount, GREATEST(COALESCE(v_due, 0), 0));
  END IF;
  UPDATE sale_returns SET refund_total = v_amount, refund_to_due = v_to_due,
         refund_cash = v_amount - v_to_due WHERE id = v_ret;
  INSERT INTO audit_log (shop_id, user_id, action, table_name, row_id, new_data)
  VALUES (p_shop, p_user, 'sale_return', 'sale_returns', v_ret,
          jsonb_build_object('sale', p_sale, 'refund', v_amount, 'restock', COALESCE(p_restock, false), 'reason', p_reason));
  RETURN v_ret;
END $$ LANGUAGE plpgsql;
