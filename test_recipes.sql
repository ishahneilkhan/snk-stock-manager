-- Run after schema.sql, logic.sql and recipes.sql. Everything is rolled back at the end.
-- Success prints: NOTICE: ALL RECIPE TESTS PASSED
BEGIN;
DO $$
DECLARE
  sh bigint; own bigint; sman bigint; sup bigint; cus bigint; rice bigint; chick bigint;
  bir bigint; plain bigint; s1 bigint; u uuid; v numeric;
BEGIN
  INSERT INTO shops (name, business_type) VALUES ('Test', 'restaurant') RETURNING id INTO sh;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (sh, 'O', 'q_owner', 'x', 'owner') RETURNING id INTO own;
  INSERT INTO users (shop_id, name, username, password_hash, role) VALUES (sh, 'S', 'q_sman', 'x', 'salesman') RETURNING id INTO sman;
  INSERT INTO suppliers (shop_id, name) VALUES (sh, 'Bazar') RETURNING id INTO sup;
  INSERT INTO customers (shop_id, name) VALUES (sh, 'Cus') RETURNING id INTO cus;
  INSERT INTO products (shop_id, name, base_unit, pack_unit, pack_size) VALUES (sh, 'Rice', 'gram', 'kg', 1000) RETURNING id INTO rice;
  INSERT INTO products (shop_id, name, base_unit, pack_unit, pack_size) VALUES (sh, 'Chicken', 'gram', 'kg', 1000) RETURNING id INTO chick;
  -- 20 kg rice at 0.065/g, 6 kg chicken at 0.22/g
  PERFORM create_purchase(sh, own, sup, 'B1', 0, jsonb_build_array(
    jsonb_build_object('product_id', rice,  'batch_no', 'R1', 'expiry_date', current_date + 200, 'qty', 20000, 'unit_cost', 0.065, 'sell_price', 0),
    jsonb_build_object('product_id', chick, 'batch_no', 'C1', 'expiry_date', current_date + 5,   'qty', 6000,  'unit_cost', 0.22,  'sell_price', 0)));
  INSERT INTO dishes (shop_id, name, price) VALUES (sh, 'Chicken Biryani', 220) RETURNING id INTO bir;
  INSERT INTO dishes (shop_id, name, price) VALUES (sh, 'Plain (no recipe yet)', 30) RETURNING id INTO plain;
  PERFORM set_recipe(sh, own, bir, jsonb_build_array(
    jsonb_build_object('product_id', rice, 'qty', 150), jsonb_build_object('product_id', chick, 'qty', 200)));

  -- 1. dish margin from current stock cost: 150*0.065 + 200*0.22 = 53.75, profit 166.25
  SELECT cost INTO v FROM dish_margin WHERE dish_id = bir;
  ASSERT v = 53.75, 'dish cost should be 53.75, got ' || v;
  ASSERT (SELECT profit FROM dish_margin WHERE dish_id = bir) = 166.25, 'profit should be 166.25';

  -- 2. selling 3 biryani takes 450 g rice and 600 g chicken; bill 660
  u := gen_random_uuid();
  s1 := create_dish_sale(sh, sman, u, 'dine', 'T5', NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('dish_id', bir, 'qty', 3)));
  ASSERT (SELECT total FROM sales WHERE id = s1) = 660, 'bill should be 660';
  ASSERT (SELECT table_no FROM sales WHERE id = s1) = 'T5', 'table kept';
  ASSERT (SELECT sellable_qty FROM product_stock WHERE product_id = rice)  = 19550, 'rice should be 19550';
  ASSERT (SELECT sellable_qty FROM product_stock WHERE product_id = chick) = 5400,  'chicken should be 5400';
  ASSERT (SELECT unit_cost FROM sale_dish_items WHERE sale_id = s1) = 53.75, 'recorded unit cost should be 53.75';

  -- 3. the same order sent again does nothing
  ASSERT create_dish_sale(sh, sman, u, 'dine', 'T5', NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('dish_id', bir, 'qty', 3))) = s1, 'retry returns same sale';
  ASSERT (SELECT sellable_qty FROM product_stock WHERE product_id = chick) = 5400, 'retry must not change stock';

  -- 4. not enough chicken: the order fails and saves nothing
  BEGIN
    PERFORM create_dish_sale(sh, sman, gen_random_uuid(), 'take', NULL, NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('dish_id', bir, 'qty', 100)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'insufficient sellable stock%', 'wrong error: ' || SQLERRM;
  END;
  ASSERT (SELECT sellable_qty FROM product_stock WHERE product_id = rice) = 19550, 'failed order must not change stock';

  -- 5. a dish without a recipe cannot be sold
  BEGIN
    PERFORM create_dish_sale(sh, sman, gen_random_uuid(), 'dine', NULL, NULL, 'cash', 0, NULL, jsonb_build_array(jsonb_build_object('dish_id', plain, 'qty', 1)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'a dish in this order has no recipe%', 'wrong error: ' || SQLERRM;
  END;

  -- 6. a salesman cannot give a discount, cannot change recipes
  BEGIN
    PERFORM create_dish_sale(sh, sman, gen_random_uuid(), 'dine', NULL, NULL, 'cash', 10, NULL, jsonb_build_array(jsonb_build_object('dish_id', bir, 'qty', 1)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'only the owner%', 'wrong error: ' || SQLERRM;
  END;
  BEGIN
    PERFORM set_recipe(sh, sman, bir, jsonb_build_array(jsonb_build_object('product_id', rice, 'qty', 1)));
    RAISE EXCEPTION 'should have failed';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE 'owner only%', 'wrong error: ' || SQLERRM;
  END;

  -- 7. an order on credit adds to the customer's due
  PERFORM create_dish_sale(sh, own, gen_random_uuid(), 'delivery', NULL, cus, 'due', 0, 0, jsonb_build_array(jsonb_build_object('dish_id', bir, 'qty', 1)));
  ASSERT (SELECT due FROM customer_balance WHERE customer_id = cus) = 220, 'customer owes 220';

  -- 8. changing the recipe later does not change the cost recorded on old sales
  PERFORM set_recipe(sh, own, bir, jsonb_build_array(jsonb_build_object('product_id', rice, 'qty', 300), jsonb_build_object('product_id', chick, 'qty', 200)));
  ASSERT (SELECT unit_cost FROM sale_dish_items WHERE sale_id = s1) = 53.75, 'old sale cost must not change';

  RAISE NOTICE 'ALL RECIPE TESTS PASSED';
END $$;
ROLLBACK;
