<p>
The DBToaster compiler can be installed on Windows, Mac OS X, and Linux platforms. The compiler supports generation of C++ and Scala programs. Depending on the chosen backend(s), it requires the following dependencies:
<ul>
  <li>Oracle JDK 7 (or above), required</li>
  <li>g++ 4.8 (or above) - optional, for compiling generated C++ programs</li>
  <li><a href="http://scala-lang.org/download/2.10.2.html">Scala 2.10.2</a> - optional, for compiling generated Scala programs</li>
  <li><a href="http://cygwin.com/">Cygwin</a> (only for Windows)</li>
</ul>

<i>Notes:</i>
<ul>
  <li>Most of the development and testing has been done on Mac OS X and Linux platforms.</li>
  <li>To use a custom C++ compiler, create a symlink <tt>gpp</tt> in the DBToaster directory that points to the compiler (e.g., <span class="code"> "ln -s /usr/local/bin/g++-4.8 gpp"</span>).</li>
  <li>Other versions of the tools/packages might work as well but have not been tested.</li>
</ul>

Visit <?= mk_link(null, "download", null); ?> to get the binaries.
</p>

<p align="center">
<iframe width="560" height="315" align="center" src="//www.youtube.com/embed/FuyVUei0uK8" frameborder="0" allowfullscreen></iframe>
</p>