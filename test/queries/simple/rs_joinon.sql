CREATE STREAM R(A int, B int)
FROM FILE '../../experiments/data/tiny_r.dat' LINE DELIMITED
csv ();

CREATE STREAM S(C int, D int)
FROM FILE '../../experiments/data/tiny_s.dat' LINE DELIMITED
csv ();

SELECT R.* FROM R JOIN S ON R.B = S.C;