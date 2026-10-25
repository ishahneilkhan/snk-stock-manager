-- Run after schema.sql, logic.sql and returns.sql. Everything is rolled back at the end.
-- Success prints: NOTICE: ALL RETURN TESTS PASSED
BEGIN;
DO $$
DECLARE
  sh bigint; own bigint; sman bigint; sup bigint; cus bigint; p bigint;
  bA bigint; bB bigint; s1 bigint; s2 bigint; r1 bigint; u uuid;
BEGIN
  INSERT INTO shops (name, business_type) VALUES ('Test', 'pharmacy') RETURNING id INTO sh;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (sh, 'O', 'r_owner', 'x', 'owner') RETURNING id INTO own;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (sh, 'S', 'r_sman', 'x', 'salesman') RETURNING id INTO sman;
  INSERT INTO suppliers (shop_id, name) VALUES (sh, 'Sup') RETURNING id INTO sup;
  INSERT INTO customers (shop_id, name) VALUES (sh, 'Cus') RETURNING id INTO cus;
  INSERT INTO products (shop_id, name, base_unit, pack_unit, pack_size) VALUES (sh, 'Napa', 'piece', 'strip', 10) RETURNING id INTO p;
  PERFORM create_purchase(sh, own, sup, 'INV1', 0, jsonb_build_array(
    jsonb_build_object('product_id', p, 'batch_no', 'A', 'expiry_date', current_date + 30,  'qty', 100, 'unit_cost', 0.8, 'sell_price', 1.0),
    jsonb_build_object('product_id', p, 'batch_no', 'B', 'expiry_date', current_date + 365, 'qty', 100, 'unit_cost', 0.9, 'sell_price', 1.2)));
  SELECT id INTO bA FROM batches WHERE product_id = p AND batch_no = 'A';
  SELECT id INTO bB FROM batches WHERE product_id = p AND batch_no = 'B';

  -- cash sale of 150: 100 from A at 1.0 + 50 from B at 1.2 = 160 (average 1.0667 per piece)
  s1 := create_sale(sh, own, gen_random_uuid(), NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 150)));
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bA) = 0 AND (SELECT qty FROM batch_stock WHERE batch_id = bB) = 50, 'setup stock';

  -- 1. return 20 and put it back: refund 21.33, goods go back to batch A
  u := gen_random_uuid();
  r1 := create_sale_return(sh, own, u, s1, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 20)), true, 'wrong item');
  ASSERT (SELECT refund_total FROM sale_returns WHERE id = r1) = 21.33, 'refund should be 21.33';
  ASSERT (SELECT refund_cash  FROM sale_returns WHERE id = r1) = 21.33, 'cash refund should be 21.33';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bA) = 20, 'batch A should have 20 back';

  -- 2. the same request again does nothing
  ASSERT create_sale_return(sh, own, u, s1, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 20)), true, 'wrong item') = r1, 'retry returns same id';
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bA) = 20, 'retry must not change stock';
  ASSERT (SELECT count(*) FROM sale_returns WHERE sale_id = s1) = 1, 'one return row';

  -- 3. cannot return more than was sold (150 sold, 20 already back, so 131 is too many)
  BEGIN
    PERFORM create_sale_return(sh, own, gen_random_uuid(), s1, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 131)), true, 'x');
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'return is more than sold%', 'wrong error: ' || SQLERRM;
  END;

  -- 4. return without putting back on the shelf: refund 10.67, stock unchanged
  PERFORM create_sale_return(sh, own, gen_random_uuid(), s1, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 10)), false, 'damaged');
  ASSERT (SELECT qty FROM batch_stock WHERE batch_id = bA) = 20, 'no restock: stock unchanged';
  ASSERT (SELECT refund_total FROM sale_returns WHERE sale_id = s1 AND restock = false) = 10.67, 'refund should be 10.67';

  -- 5. a salesman cannot make returns
  BEGIN
    PERFORM create_sale_return(sh, sman, gen_random_uuid(), s1, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 1)), true, 'x');
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'owner only%', 'wrong error: ' || SQLERRM;
  END;

  -- 6. a return needs a reason
  BEGIN
    PERFORM create_sale_return(sh, own, gen_random_uuid(), s1, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 1)), true, '  ');
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'a reason is required%', 'wrong error: ' || SQLERRM;
  END;

  -- 7. return from a sale on credit: the refund reduces what the customer owes
  s2 := create_sale(sh, own, gen_random_uuid(), cus, 'due', 0, 0, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 30)));
  ASSERT (SELECT due FROM customer_balance WHERE customer_id = cus) = 32, 'customer owes 32';  -- 20 x 1.0 + 10 x 1.2
  r1 := create_sale_return(sh, own, gen_random_uuid(), s2, jsonb_build_array(jsonb_build_object('product_id', p, 'qty', 5)), true, 'changed mind');
  ASSERT (SELECT refund_to_due FROM sale_returns WHERE id = r1) = 5.33, 'refund goes to the due';
  ASSERT (SELECT refund_cash   FROM sale_returns WHERE id = r1) = 0,    'no cash handed back';
  ASSERT (SELECT due FROM customer_balance WHERE customer_id = cus) = 26.67, 'customer now owes 26.67';

  RAISE NOTICE 'ALL RETURN TESTS PASSED';
END $$;
ROLLBACK;
