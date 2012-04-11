/* Result on vwap5k: 
      sum       
----------------
 76452380068302
(1 row)

result on vwap100: 389562600
 */

CREATE STREAM bids(t FLOAT, id INT, broker_id INT, volume FLOAT, price FLOAT)
  FROM FILE '../../experiments/data/vwap5k.csv'
  LINE DELIMITED orderbook (book := 'bids', brokers := '10', 
                            deterministic := 'yes');

CREATE STREAM asks(t FLOAT, id INT, broker_id INT, volume FLOAT, price FLOAT)
  FROM FILE '../../experiments/data/vwap5k.csv'
  LINE DELIMITED orderbook (book := 'asks', brokers := '10', 
                            deterministic := 'yes');

-- look at spread between significant orders
SELECT sum(a.price + -1*b.price) AS psp 
FROM bids b, asks a
WHERE ( b.volume > 0.0001 * (SELECT sum(b1.volume) FROM bids b1) )
AND ( a.volume > 0.0001 * (SELECT sum(a1.volume) FROM asks a1) );
