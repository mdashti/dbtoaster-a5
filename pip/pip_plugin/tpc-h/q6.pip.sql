\timing
ALTER SEQUENCE pip_var_id RESTART WITH 1;

---------------------- Initialization -------------------------------

CREATE TEMPORARY VIEW production_history AS
  SELECT 
    "L_PARTKEY" AS part, 
    "L_SUPPKEY" AS supplier,
    extract(year from "O_ORDERDATE") AS year, 
    sum("L_QUANTITY") AS count 
  FROM 
    "LINEITEM", 
    "ORDERS" 
  WHERE 
    "L_PARTKEY" <= 5000
    AND "O_ORDERKEY" = "L_ORDERKEY" 
    AND extract (year from "O_ORDERDATE") < 1998
    AND extract (year from "O_ORDERDATE") >= 1992
  GROUP BY 
    part, supplier, year;

CREATE TEMPORARY VIEW production_stats AS
  SELECT   part, max(count) as supply_max, stddev(count) as supply_dev
  FROM     production_history
  GROUP BY part;

CREATE TEMPORARY TABLE supply_tbl AS
  SELECT
    part,  
    CREATE_VARIABLE('Exponential', row(supply_dev*0.000001)) + (supply_max) AS supply
  FROM
    production_stats;

CREATE TEMPORARY VIEW increase_per_customer AS
  SELECT
    newcount/oldcount AS increase, customer
  FROM (
    SELECT 
      "O_CUSTKEY" AS customer,
      SUM(extract(year from "O_ORDERDATE")-1996.0) AS newcount,
      SUM(1997.0-extract(year from "O_ORDERDATE")) AS oldcount
    FROM "ORDERS"
    WHERE extract(year from "O_ORDERDATE") = 1996.0 OR extract(year from "O_ORDERDATE") = 1997.0
    GROUP BY customer
    ) AS counts
  WHERE
    oldcount > 0;

CREATE TEMPORARY TABLE demand_tbl AS
  SELECT
    part, price,
    (CREATE_VARIABLE('Exponential', row(increase)) + 1) * quantity AS customer_demand
  FROM
    (SELECT
      "L_PARTKEY" AS part,
      sum(("L_EXTENDEDPRICE" * "L_QUANTITY" * (1-"L_DISCOUNT"))) AS price,
      sum("L_QUANTITY") AS quantity,
      avg(increase) AS increase
    FROM
      "ORDERS",
      increase_per_customer,
      "LINEITEM"
    WHERE
      "L_PARTKEY" <= 5000 
      AND "O_CUSTKEY" = customer
      AND "O_ORDERKEY" = "L_ORDERKEY"
    GROUP BY
      part
    ) AS average_increase;

CREATE TEMPORARY TABLE sample_instance(num integer);
INSERT INTO sample_instance(num) VALUES 
  (00), (01), (02), (03), (04), (05), (06), (07), (08), (09),
  (10), (11), (12), (13), (14), (15), (16), (17), (18), (19),
  (20), (21), (22), (23), (24), (25), (26), (27), (28), (29);

--DROP TABLE IF EXISTS correct_results;
--CREATE TABLE correct_results AS
--  SELECT
--    part,
--    expectation(customer_demand-supply, inputs, 10000) AS underproduction
--  FROM
--    (SELECT
--      demand_tbl.part,
--      customer_demand,
--      supply
--    FROM
--      demand_tbl,
--      supply_tbl
--    WHERE
--      customer_demand > supply
--      AND demand_tbl.part = supply_tbl.part
--    ) AS inputs;

CREATE TEMPORARY TABLE results AS
  SELECT
    part, num,
    expectation(customer_demand-supply, inputs, 1000) AS underproduction
  FROM
    (SELECT
      demand_tbl.part,
      customer_demand,
      supply
    FROM
      demand_tbl,
      supply_tbl
    WHERE
      customer_demand > supply
      AND demand_tbl.part = supply_tbl.part
    ) AS inputs,
    sample_instance;
--  GROUP BY 
--    demand_tbl.part;

SELECT avg(sqrt(underproduction)), count(*)
FROM   (
          SELECT    results.part, avg((results.underproduction-correct_results.underproduction)*(results.underproduction-correct_results.underproduction)/(correct_results.underproduction*correct_results.underproduction)) as underproduction
          FROM      results, correct_results
          WHERE     results.part = correct_results.part AND results.underproduction != 'Infinity' AND correct_results.underproduction != 'Infinity'
          GROUP BY  results.part
       ) resultdevs;