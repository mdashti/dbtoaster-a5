q

select    s_nationkey, sum((p_retailprice + (-1 * ps_supplycost)) * ps_availqty) from   part p, partsupp ps, supplier s where   p_partkey = ps_partkey AND s_suppkey = ps_suppkey group by   s_nationkey

Q.0
0/8
qPART1
PART.0=>dom_P__P_PARTKEY
select S.S_NATIONKEY,PS.PS_PARTKEY,sum(PS.PS_AVAILQTY) from PARTSUPP PS, SUPPLIER S where S.S_SUPPKEY = PS.PS_SUPPKEY group by S.S_NATIONKEY,PS.PS_PARTKEY
dom_P__P_PARTKEY
Q.1,Q.0
0/8
qPART2
PART.0=>dom_P__P_PARTKEY
select S.S_NATIONKEY,PS.PS_PARTKEY,sum((PS.PS_SUPPLYCOST*PS.PS_AVAILQTY)) from PARTSUPP PS, SUPPLIER S where S.S_SUPPKEY = PS.PS_SUPPKEY group by S.S_NATIONKEY,PS.PS_PARTKEY
dom_P__P_PARTKEY
Q.1,Q.0
0/8
qPARTSUPP1
PARTSUPP.0=>dom_PS__PS_PARTKEY
select P.P_PARTKEY,sum(P.P_RETAILPRICE) from PART P group by P.P_PARTKEY
dom_PS__PS_PARTKEY
Q.0
0/8
qPARTSUPP2
PARTSUPP.1=>dom_PS__PS_SUPPKEY
select S.S_NATIONKEY,S.S_SUPPKEY,sum(1) from SUPPLIER S group by S.S_NATIONKEY,S.S_SUPPKEY
dom_PS__PS_SUPPKEY
Q.1,Q.0
0/8
qPARTSUPP3
PARTSUPP.0=>dom_PS__PS_PARTKEY
select P.P_PARTKEY,sum(1) from PART P group by P.P_PARTKEY
dom_PS__PS_PARTKEY
Q.0
0/8
qSUPPLIER1
SUPPLIER.0=>dom_S__S_SUPPKEY
select PS.PS_SUPPKEY,sum((P.P_RETAILPRICE*PS.PS_AVAILQTY)) from PART P, PARTSUPP PS where P.P_PARTKEY = PS.PS_PARTKEY group by PS.PS_SUPPKEY
dom_S__S_SUPPKEY
Q.0
0/8
qSUPPLIER2
SUPPLIER.0=>dom_S__S_SUPPKEY
select PS.PS_SUPPKEY,sum((PS.PS_SUPPLYCOST*PS.PS_AVAILQTY)) from PARTSUPP PS, PART P where P.P_PARTKEY = PS.PS_PARTKEY group by PS.PS_SUPPKEY
dom_S__S_SUPPKEY
Q.0
0/8
qPART1SUPPLIER1
PART.0=>dom_P__P_PARTKEY,SUPPLIER.0=>dom_S__S_SUPPKEY
select PS.PS_PARTKEY,PS.PS_SUPPKEY,sum(PS.PS_AVAILQTY) from PARTSUPP PS group by PS.PS_PARTKEY,PS.PS_SUPPKEY
dom_P__P_PARTKEY,dom_S__S_SUPPKEY
Q.0,Q.1
0/8
qPART2SUPPLIER1
PART.0=>dom_P__P_PARTKEY,SUPPLIER.0=>dom_S__S_SUPPKEY
select PS.PS_PARTKEY,PS.PS_SUPPKEY,sum((PS.PS_SUPPLYCOST*PS.PS_AVAILQTY)) from PARTSUPP PS group by PS.PS_PARTKEY,PS.PS_SUPPKEY
dom_P__P_PARTKEY,dom_S__S_SUPPKEY
Q.0,Q.1
0/8
