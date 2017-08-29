<script src="http://d3js.org/d3.v3.min.js"></script>

<div id="staticimg">
   <img src="perf.png" style="width:100%"/>
</div>
<div id="mcb_dbx", class="magic_chkbox bardbx">
   <input type="checkbox" class="filter_data" id="cb_dbx" name="" checked /> 
   <label class="checkbox-inline" id="lbl_dbx" for="cb_dbx">&nbsp;DBX</label>
</div>
<div id="mcb_spy", class="magic_chkbox barspy">
   <input type="checkbox" class="filter_data" id="cb_spy" name="" checked /> 
   <label class="checkbox-inline" id="lbl_spy" for="cb_spy">&nbsp;SPY</label>
</div>
<div id="mcb_rep", class="magic_chkbox barrep">
   <input type="checkbox" class="filter_data" id="cb_rep" name="" /> 
   <label class="checkbox-inline" id="lbl_rep" for="cb_rep">&nbsp;REP</label>
</div>
<div id="mcb_ivm", class="magic_chkbox barivm">
   <input type="checkbox" class="filter_data" id="cb_ivm" name="" /> 
   <label class="checkbox-inline" id="lbl_ivm" for="cb_ivm">&nbsp;IVM</label>
</div>
<div id="mcb_prscala", class="magic_chkbox barprscala">
   <input type="checkbox" class="filter_data" id="cb_prscala" name="" /> 
   <label class="checkbox-inline" id="lbl_prscala" for="cb_prscala">&nbsp;R1&nbsp;(Scala)</label>
</div>
<div id="mcb_prcpp", class="magic_chkbox barprcpp">
   <input type="checkbox" class="filter_data" id="cb_prcpp" name="" /> 
   <label class="checkbox-inline" id="lbl_prcpp" for="cb_prcpp">&nbsp;R1&nbsp;(C++)</label>
</div>
<div id="mcb_scala", class="magic_chkbox barscala">
   <input type="checkbox" class="filter_data" id="cb_scala" name="" /> 
   <label class="checkbox-inline" id="lbl_scala" for="cb_scala">&nbsp;R2.1&nbsp;(Scala)</label>
</div>
<div id="mcb_cpp", class="magic_chkbox barcpp">
   <input type="checkbox" class="filter_data" id="cb_cpp" name="" checked /> 
   <label class="checkbox-inline" id="lbl_cpp" for="cb_cpp">&nbsp;R2.1&nbsp;(C++)</label>
</div>

<div id="bakeoff", class="bakeoff">
</div>

<script>
var tooltip = d3.select("body")
   .append("div")
   .attr("class", "datatooltip")
   .style("position", "absolute")
   .style("z-index", "10")
   .style("visibility", "hidden");

var margin = {top: 20, right: 20, bottom: 70, left: 60},
    width = 700 - margin.left - margin.right,
    height = 300 - margin.top - margin.bottom;

var bakeoff = d3.select(".bakeoff")

var x = d3.scale.ordinal().rangeRoundBands([0, width], .05);
var y = d3.scale.log().range([height, 0]);

var svg = bakeoff.append("svg")
      .attr("height", height + margin.top + margin.bottom)
      .attr("width", width + margin.left + margin.right)
   .append("g")
      .attr("transform",
         "translate(" + margin.left + "," + margin.top + ")");

function drawBars(rawData, rawGroups) {
   var groups = rawGroups.filter(function (g) {
      return d3.select("#cb_" + g).node().checked;
   });
   var data = rawData.filter(function (d) {
      return groups.indexOf(d.group) >= 0;
   });

   var barwidth = x.rangeBand() / (groups.length + 1);
   var bars = svg.selectAll("rect").data(data);

   bars.enter().append("rect")
      .attr("class", function(d) { return "bar" + d.group; })
      .attr("x", function(d) { return x(d.query) + (0.5 + groups.indexOf(d.group)) * barwidth; })
      .attr("width", barwidth)
      .on("mouseover", function(d) { return tooltip.text(d.v + " Tuples/s").style("visibility", "visible"); })
      .on("mousemove", function(d) { return tooltip.style("top", (event.pageY - 10) + "px").style("left",(event.pageX + 10) + "px"); })
      .on("mouseout", function(d) { return tooltip.style("visibility", "hidden");})
      .attr("y", height)
      .attr("height", 0)
      .transition()
      .attr("y", function(d) { return y(d.v); })
      .attr("height", function(d) { return height - y(d.v); });

   bars.transition()
      .attr("class", function(d) { return "bar" + d.group; })
      .attr("x", function(d) { return x(d.query) + (0.5 + groups.indexOf(d.group)) * barwidth; })
      .attr("width", barwidth)
      .attr("y", height)
      .attr("height", 0)
      .attr("y", function(d) { return y(d.v); })
      .attr("height", function(d) { return height - y(d.v); });

   bars.exit().transition().attr("y", height).attr("height", 0).remove();
}

// var rawInputBackup = [
//    { query: "Q1", dbx: "17.74", spy: "29.46", rep: "6.41", ivm: "11.16", prscala: "40481.05", prcpp: "17766.32", scala: "203183.96", cpp: "639466.80" },
//    { query: "Q2", dbx: "10.74", spy: "1.01", rep: "0.75", ivm: "60.33", prscala: "15533.11", prcpp: "17743.77", scala: "190245.24", cpp: "1092895.25" },
//    { query: "Q3", dbx: "18.22", spy: "22.55", rep: "3.58", ivm: "14.03", prscala: "47878.65", prcpp: "22065.65", scala: "252867.93", cpp: "2316431.18" },
//    { query: "Q4", dbx: "32.3", spy: "252.04", rep: "8.42", ivm: "7678.18", prscala: "48451.74", prcpp: "26640.23", scala: "285413.06", cpp: "3080646.78" },
//    { query: "Q5", dbx: "9.67", spy: "19.05", rep: "1.1", ivm: "4.14", prscala: "934.62", prcpp: "32.5", scala: "10285.06", cpp: "3911.36" },
//    { query: "Q6", dbx: "44.24", spy: "361.97", rep: "28.29", ivm: "26910.07", prscala: "45197.81", prcpp: "0.02", scala: "292694.60", cpp: "6103389.89" },
//    { query: "Q7", dbx: "3.84", spy: "14.1", rep: "0.17", ivm: "10.17", prscala: "1714.78", prcpp: "3.11", scala: "48391.02", cpp: "65735.34" },
//    { query: "Q8", dbx: "34.83", spy: "23.88", rep: "0.23", ivm: "0.25", prscala: "5990.67", prcpp: "25.51", scala: "85850.09", cpp: "225414.81" },
//    { query: "Q9", dbx: "6.75", spy: "23.74", rep: "0.07", ivm: "0.8", prscala: "3497.9", prcpp: "5867.49", scala: "59115.03", cpp: "72325.08" },
//    { query: "Q10", dbx: "4.6", spy: "38.23", rep: "1.34", ivm: "4.92", prscala: "48364.73", prcpp: "20520.93", scala: "263716.93", cpp: "2250119.95" },
//    { query: "Q11", dbx: "3.74", spy: "12.32", rep: "0.23", ivm: "0.12", prscala: "48079.04", prcpp: "1.23", scala: "5268.75", cpp: "11059.96" },
//    { query: "Q12", dbx: "24.71", spy: "74.47", rep: "2.06", ivm: "7576.58", prscala: "47028.36", prcpp: "23801.9", scala: "261958.66", cpp: "2924223.15" },
//    { query: "Q13", dbx: "9.64", spy: "10.9", rep: "0.12", ivm: "0.1", prscala: "27.12", prcpp: "4.18", scala: "1105.56", cpp: "2408.21" },
//    { query: "Q14", dbx: "39.6", spy: "464.88", rep: "0.99", ivm: "1.01", prscala: "45054.04", prcpp: "24396.6", scala: "262743.66", cpp: "4174205.74" },
//    { query: "Q15", dbx: "2.49", spy: "6.14", rep: "0.12", ivm: "0.08", prscala: "17.64", prcpp: "6.08", scala: "44.71", cpp: "76.80" },
//    { query: "Q16", dbx: "2.94", spy: "8.82", rep: "2.01", ivm: "2.0", prscala: "220.96", prcpp: "5.28", scala: "529.64", cpp: "489.88" },
//    { query: "Q17", dbx: "11.77", spy: "19.64", rep: "3.4", ivm: "1373.52", prscala: "43553.37", prcpp: "23993.45", scala: "173687.57", cpp: "850980.69" },
//    { query: "Q18", dbx: "1.2", spy: "11.16", rep: "2.45", ivm: "2.95", prscala: "27.49", prcpp: "40.73", scala: "212548.32", cpp: "1010914.80" },
//    { query: "Q19", dbx: "23.84", spy: "0.57", rep: "0.06", ivm: "187.78", prscala: "338.94", prcpp: "68.4", scala: "1669.43", cpp: "2864.97" },
//    { query: "Q20", dbx: "7.16", spy: "33.63", rep: "13.91", ivm: "502.33", prscala: "28596.03", prcpp: "2003.73", scala: "192265.18", cpp: "678672.77" },
//    { query: "Q21", dbx: "8.72", spy: "14.72", rep: "1.65", ivm: "8.5", prscala: "25470.22", prcpp: "6573.43", scala: "205210.87", cpp: "656460.94" },
//    { query: "Q22", dbx: "36.05", spy: "58.22", rep: "0.39", ivm: "0.47", prscala: "3379.37", prcpp: "196.89", scala: "27215.12", cpp: "78018.93" }
// ];

(function() {
   var hiddenElements = [ "bakeoff", "mcb_dbx", "mcb_spy", "mcb_rep", "mcb_ivm", "mcb_prscala", "mcb_prcpp", "mcb_scala", "mcb_cpp"];
   for (var i = 0; i < hiddenElements.length; i++) {
      document.getElementById(hiddenElements[i]).style.display = 'none'; 
   }
 })();

d3.csv("data/bakeoff.csv", function(error, rawInput) 
{
   var data = [];
   var groups = ["dbx", "spy", "rep", "ivm", "prscala", "prcpp", "scala", "cpp"];

   rawInput.forEach(function (d) {
      groups.forEach(function (g) {
         var newData = { query: d.query, group: g, v: d[g] };
         data.push(newData);
      });
   });

   x.domain(data.map(function(d) { return d.query; }));
   y.domain([1, d3.max(data, function(d) { return Math.max(d.v); })]).nice();

   var xAxis = d3.svg.axis()
      .scale(x)
      .orient("bottom");

   var yAxis = d3.svg.axis()
      .scale(y)
      .orient("left")
      .ticks(10);

   drawBars(data, groups);

   svg.append("g")
      .attr("class", "x axis")
      .attr("transform", "translate(0," + height + ")")
      .call(xAxis)
   .selectAll("text")
      .style("text-anchor", "end")
      .attr("dx", "-.8em")
      .attr("dy", "-.55em")
      .attr("transform", "rotate(-90)" );

   svg.append("g")
      .attr("class", "y axis")
      .call(yAxis)
   .append("text")
      .attr("transform", "rotate(-90)")
      .attr("dy", "-3.5em")
      .style("text-anchor", "end")
      .text("Average Refresh Rate (1/s)");

   d3.selectAll(".filter_data").on("change", function() {
      drawBars(data, groups);
   });
   $("#staticimg").hide();
   $("#bakeoff").show();
   $(".magic_chkbox").show();
});

</script>

<p><i>If you cannot see the above graphs, please <a href="perf.png">click here</a>. The underlying performance measurement data can be downloaded from <a href="data/bakeoff.csv">here</a>.</i></p>

<p>The above graphs show a performance comparison of DBToaster-generated query engines against a commercial database system (DBX), a commercial stream processor (SPY), and several naive query evaluation strategies implemented in DBToaster that do not involve the Higher-Order incremental view maintenance. (The commercial systems remain anonymous in accordance with the terms of their licensing agreements).</p>

<p>In addition, the performance comparison covers generated C++ and Scala programs from both Release 1 (R1) and Release 2 (the current release - R2) releases, in order to compare the performance improvements gained in the latest release.</p>

<p>Performance is measured in terms of the rate at which each system can produce up-to-date (fresh) views of the query results.  As you can see, DBToaster regularly outperforms the commercial systems by <b>3-6 orders of magnitude.</b></p>

<p>The graphs show the performance of each system on a set of realtime data-warehousing queries based on the TPC-H query benchmark.  These queries are all included as examples in the DBToaster distribution.</p>

<p>REP (Depth-0) represents a naive query evaluation strategy where each refresh requires a full re-evaluation of the entire query.  IVM (Depth-1) is a well known technique called Incremental View Maintenance (we discuss the distinctions in depth in our technical report).  Both of these (REP and IVM) were implemented by a DBToaster-generated engine.</p>

<p>The experiments are performed on a single-socket Intel Xeon E5- 2620 (6 physical cores), 128GB of RAM, RHEL 6, and Open-JDK 1.6.0 28. Hyper-threading, turbo-boost, and frequency scaling are disabled to achieve more stable results.</p>

<p>We used LMS 0.3, running with Scala 2.10 on the Hotspot 64-bit server VM having 14 GB of heap memory, and the generated code was compiled with the -optimise option of the Scala compiler.</p>

<p>A stream synthesized from a scaling factor 0.1 database (100MB) is used for performing the experiments (with an upper limit of 2 hours), while our scaling experiments extend these results up to a scaling factor of 10 (10 GB).</p>
