
<a name="quickstart"/>
<?=chapter("Quickstart Guide")?>

<?=section("Prerequisites")?>
<ul>
	<li>DBToaster Beta1</li>
	<li>Scala 2.9.2</li>
	<li>JVM (preferably a 64-bit version)</li>
</ul>
<i>Note:</i> The following steps have been tested on Fedora 14 (64-bit) and Ubuntu 12.04 (32-bit), the commands may be slightly different for other operating systems

<?=chapter("Compiling and running your first query")?>
We start with a simple query that looks like this:
<div class="codeblock">
CREATE TABLE R(A int, B int) 
  FROM FILE '../../experiments/data/tiny_r.dat' LINE DELIMITED
  CSV (fields := ',');

CREATE STREAM S(B int, C int) 
  FROM FILE '../../experiments/data/tiny_s.dat' LINE DELIMITED
  CSV (fields := ',');

SELECT SUM(r.A*s.C) as RESULT FROM R r, S s WHERE r.B = s.B;
</div>
This query should be saved to a file named <tt>rs_example.sql</tt>.
<p>
To compile the query to Scala code, we invoke the DBToaster compiler with the following command:
<div class="codeblock">$&gt; bin/dbtoaster -l scala -o rs_example.scala rs_example.sql</div>
This command will produce a file <tt>rs_example.scala</tt> (or any other filename specified by the <tt>-o [filename]</tt> switch) which contains the Scala code representing the query.
<p>
To compile the query to a JAR file, we invoke the DBToaster compiler with the <tt>-c [JARname]</tt> switch:
<div class="codeblock">$&gt; bin/dbtoaster -l scala -c rs_example rs_example.sql</div>
<i>Note:</i> The ending <tt>.jar</tt> is automatically appended to the name of the JAR.
<p>
The resulting JAR contains a main function that can be used to test the query. It can be run using the following command assuming that the Scala DBToaster library can be found in the subdirectory <tt>lib/dbt_scala</tt>:
<div class="codeblock">
$&gt; scala -classpath "rs_example.jar:lib/dbt_scala/dbtlib.jar" org.dbtoaster.RunQuery
</div>
After all tuples in the data files were processed, the result of the query will be printed:
<div class="codeblock">
Run time: 0.042 ms
&lt;RESULT&gt;156 &lt;/RESULT&gt;
</div>

<a name="generatedcode"/>
<?=chapter("Generated Code Reference")?>
The following example shows how a query can be ran from your own Scala code. Suppose we have a the following source code in <tt>main_example.scala</tt>:
<div class="codeblock">
import org.dbtoaster.Query

package org.example {
  object MainExample {
    def main(args: Array[String]) {
      Query.run()
      Query.printResults()
    }
  }
}
</div>
This program will start the query and output its result after it finished.
<p>
The program can be compiled to <tt>main_example.jar</tt> using the following command (assuming that the query was compiled to a file named <tt>rs_example.jar</tt>):
<div class="codeblock">
$&gt; scalac -classpath "rs_example.jar" -d main_example.jar main_example.scala
</div>
The resulting program can now be launched with:
<div class="codeblock">
$&gt; scala -classpath "main_example.jar:rs_example.jar:lib/dbt_scala/dbtlib.jar" org.example.MainExample
</div>