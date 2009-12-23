
require 'getoptlong';
require 'logger';
require 'thread';
require 'pty';
require 'util/ok_mixins';
require 'slicer/remotemanager';


class SlicerNodeHandler
  attr_reader :verbosity, :is_master;
  attr_writer :message_handler;

  include Java::org::dbtoaster::cumulus::slicer::SlicerNode::SlicerNodeIFace;

  def initialize(config_file, verbosity = :quiet)
    @config_file = config_file;
    @monitor_intake = Queue.new;
    @spread_path = $config.spread_path;
    @verbosity = verbosity;
    @is_master = false;
    @message_handler = nil;
    
    @monitor = Thread.new(@monitor_intake) do |intake|
      clients = Array.new;
      finished = false;
      master = false;
      until finished do
        cmd = intake.pop;
        case cmd[0]
          when :data    then clients.each { |c| c.receive_log(cmd[1]) };
          when :client  then clients.push(cmd[1]);
          when :exit    then finished = true;
          when :master  then master = true;
        end
      end
      puts "Leaving monitor thread!";
    end
  end
  
  def verbosity_flag 
    case @verbosity
      when :quiet then "-q"
      when :normal then ""
      when :verbose then "-v"
    end
  end
  
  def start_process(cmd)
    #cmd = cmd + " 1>&2";
    @monitor_intake.push([:data, "Running: " + cmd ]);
    Thread.new(cmd, @monitor_intake) do |cmd, output|
      begin
        puts "Spawning: #{cmd}"
        PTY.spawn(cmd) do |stdin, stdout, pid|
          puts "Starting process pid #{pid}"
          at_exit { puts "Killing #{cmd}"; Process.kill("HUP", pid) };
          stdin.each { |line| output.push([:data, line]); }
        end
      #rescue PTY::ChildExited
      #  puts "Ran #{cmd}"
      end
    end
  end
  
  def start_switch()
    start_process(
      @spread_path+"/bin/chef.sh " + verbosity_flag + " " + @config_file
    )
  end
  
  def start_node(port)
    start_process(
      @spread_path+"/bin/node.sh -p " + port.to_s + " " + verbosity_flag + " " + @config_file
    )
  end
  
  def start_client()
    raise "To run the client, the configuration file must have a source line" unless $config.client_debug["sourcefile"];
    start_process(
      @spread_path+"/bin/client.sh -q -s " + 
        if $config.client_debug["ratelimit"] then "-l " + $config.client_debug["ratelimit"].to_s + " " else "" end +
        $config.client_debug["transforms"].collect { |t| "-t '" + t + "'" }.join(" ") + " " +
        $config.client_debug["projections"].collect { |pr| "-u '" + pr + "'"}.join(" ") + " " +
        $config.client_debug["upfront"].collect { |up| "--upfront " + up }.join(" ") + " " +        
        "-h " + $config.client_debug["sourcefile"].to_s
    )
  end
  
  def start_logging(host)
    @monitor_intake.push([:client, SlicerNode::Client.connect(host)]);
  end
  
  def receive_log(log_message)
    if @is_master then
      if @message_handler.nil? then 
        puts log_message;
      else 
        @message_handler = @message_handler.call(log_message, @message_handler)
      end
    end
  end
  
  def declare_master(&message_handler);
    @monitor_intake.push([:client, self]) unless @is_master;
    @is_master = true;
    @message_handler = message_handler;
  end
  
  def poll_stats()
    `ps aux`.split("\n").delete_if { |line| /org.dbtoaster.cumulus.*Node/.match(line).nil? }.join("\n");
  end
  
  def shutdown()
    @monitor_intake.push([:exit]);
  end

end

class PrimarySlicerNodeHandler < SlicerNodeHandler
  include Java::org::dbtoaster::cumulus::slicer::SlicerNode::PrimarySlicerNodeIFace;
  
  def spin_up_slicers(*slicer_nodes)
    puts "Spinning up slicers #{slicer_nodes.length}"
    slicer_nodes.collect do |node|
      [
        node, 
        Thread.new(node) do |node|
          puts "Starting slicer manager for #{node}"; 
          manager = SlicerNode::Manager.new(node, $config.spread_path, $config_file);
          puts "Starting slicer client for #{node}";
          sleep(5);
          manager.client.start_logging(`hostname`.chomp);
          Thread.current[:client] = manager.client;
        end
      ]
    end.collect_hash do |nt|
      node, init_thread = nt
      puts "Joining slicer client thread";
      init_thread.join;
      puts "Slicer for #{node} is active";
      [node, init_thread[:client]]
    end
  end

  def build_chef_internal_nodes(fanout,level,parent,addresses,addr_idx)
    switches = Hash.new
    if level == 0 then
      switches[parent] = addresses[addr_idx...(addr_idx+fanout)]
    else
      subtree_nodes=(fanout**level)
      (0...fanout).each do |i|
        switches = switches.merge(build_chef_internal_nodes(
          fanout,level-1,addresses[addr_idx+i],addresses,(addr_idx+fanout)+i*subtree_nodes))
      end
      switches[parent] = addresses[addr_idx...(addr_idx+fanout)];
    end
    switches;
  end

  def build_chef_forwarding_tree(depth, fanout)
    num_nodes = (fanout**(depth+1)-1)/(fanout-1);
    leaf_nodes = fanout**depth;

    switches = Hash.new
    node_addresses = $config.nodes.to_a.delete_if do |node,node_info|
      node_info["address"].getHostName == "localhost"

    if num_nodes > $config.nodes.size then
      puts "Invalid chef forwarding tree, requested #{num_nodes} forwarders, "+
        "#{$config.nodes.size} nodes available."
      puts "Defaulting to 1 chef."
      switches[$config.switch] =
        [$config.nodes.collect { |node, node_info| node_info["address"] }, 1]
    else
      if (leaf_nodes % $config.nodes.size != 0) then
        puts "Non-uniform forwarding workload detected. Last node will do less work..."
      end

      node_addr_idx = 0;

      # Build the leaf layer.
      nodes_per_leaf = $config.nodes.size / leaf_nodes;
      (0...leaf_nodes).each do |leafid|
        node_addr = node_addresses[node_addr_idx];
        switch_addr = java.net.InetSocketAddress.new(node_addr.getHostName, 52981);
        switches[switch_addr] =
          [node_addresses[node_addr_idx...(node_addr_idx+nodes_per_leaf)], 1];
        node_addr_idx += nodes_per_leaf
      end

      # Build internal nodes.
      switches.merge(build_chef_internal_nodes(
        fanout,depth-1,$config.switch,node_addresses,node_addr_idx));
    end
    switches;
  end

  def build_chef_flat_forwarding_tree()
    switches = Hash.new
    node_addresses = $config.nodes.to_a.delete_if do |node,node_info|
      node_info["address"].getHostName == "localhost"
    end.collect { |node, node_info| node_info["address"] }
    if $config.num_switches == 0 then
      switches[$config.switch] =
        [$config.nodes.collect { |node, node_info| node_info["address"] }, 1]
    else
      if ($config.num_switches < $config.nodes.size) &&
        ($config.nodes.size % $config.num_switches == 0)
        then
        nodes_per_switch = $config.nodes.size / $config.num_switches;
        (0...$config.num_switches).each do |switchid|
          node_addr = node_addresses[switchid]
          startidx=switchid*nodes_per_switch
          endidx=((switchid+1)*nodes_per_switch)
          switch_addr = java.net.InetSocketAddress.new(node_addr.getHostName, 52981);
          switches[switch_addr] = [node_addresses[startidx...endidx], 1]
        end
      else
        puts "Invalid # switches: #{$config.num_switches}, must be a factor of #{$config.nodes.size}"
      end
      switch_forwarders = [switches.keys(), 0]
      switches[$config.switch] = switch_forwarders
    end
    switches
  end

  def print_forwarding_tree(switches)
    puts "========================"
    puts "Created forwarding tree:"
    switches.each_pair do |p,ch|
      children = ch.collect { |c| c.getHostName }.join(",");
      puts "Parent: #{p.getHostName} children: #{children}"
    end
    puts "========================"
  end

  def bootstrap()
    $pending_servers = $config.nodes.size + 1; # the +1 is for the switch
    $local_node.declare_master do |log_message, handler|
      # This block gets executed every time we get a log message from one of our clients;
      # we use it to figure out when the switch/nodes have all started so we can initialize the
      # client.  After that point, returning nil removes this block from the loop.

      if /Starting Cumulus Server/.match(log_message) then
        $pending_servers -= 1 
        #Logger.info { "A server just came up; #{$pending_servers} servers left" }
        puts "A server just came up; #{$pending_servers} servers left"
      end
      if $pending_servers <= 0 then
        sleep(20)
        #Logger.info { "Server Initialization complete, Starting Client..." };
        puts "Server Initialization complete, Starting Client..." ;
        $clients[$config.switch.getHostName].start_client
      end
      puts log_message;
      if $pending_servers > 0 then handler else nil end;
    end

    switches = build_chef_flat_forwarding_tree()
    print_forwarding_tree(switches)

    nodes = []
    $config.nodes.each do |node, node_info|
      puts "Launching #{node_info['address'].getHostName}"
      nodes.push(node_info["address"].getHostName);
    end
    nodes.push($config.switch.getHostName);
    
    $clients = spin_up_slicers(*(nodes.to_a.delete_if { |n| n == "localhost" }));
    $clients["localhost"] = $local_node;
    
    #Logger.info { "Starting Nodes..." };
    puts "Starting Nodes..." ;
    $config.nodes.each do |node, node_info|
      #Logger.info { "Starting : #{node} @ #{node_info["address"].getHostName}" };
      puts "Starting : #{node} @ #{node_info["address"].getHostName}" ;
      $clients[node_info["address"].getHostName].start_node(node_info["address"].getPort);
    end
    
    puts "Starting Switches"
    switches.each do |switch_node, clients_and_type|
      #Logger.info { "Starting Switch @ #{switch_node.getHostName}..." };
      puts "Starting Switch @ #{switch_node.getHostName}..."
      $clients[switch_node.getHostName].start_switch;
    end

    # Wait for switches to start up -- this is a hack for now.
    sleep(20)

    switches.each do |switch_node, clients_and_type|
      clients, forward_to_nodes = clients_and_type
      puts "Setting Switch forwarders @ #{switch_node.getHostName}"
      ChefNode.getClient(switch_node).set_forwarders(clients, forward_to_nodes);
    end
  
    #Logger.info { "Starting Monitor" }
    puts "Starting Monitor";
    monitor = SlicerMonitor.new($clients.keys.delete_if { |c| c == "localhost" }.uniq);
  
    #Logger.info { "Sleeping until finished" };
  end  
end

module SlicerNode 
  class Manager
    def initialize(host, spread_path, config_file)
      @host = host;
      @process = RemoteProcess.new(
        "cd #{spread_path}; ./bin/slicer.sh --serve #{config_file}",
        host, 
        true
      )
      @ready = false;
    end
    
    def running
      @process.status;
    end
    
    def log
      ret = "";
      ret += @process.log.pop until @process.log.empty?
      ret;
    end
    
    def check_error
      puts log unless running;
      running;
    end
    
    def client
      #Logger.warn { "Waiting for slicer to spawn on : #{@host}" }
      puts "Waiting for slicer to spawn on : #{@host}"
      @ready = /====> Server Ready <====/.match(@process.log.pop) until @ready
      #Logger.warn { "Slicer spawned on : #{@host}" }
      puts "Slicer spawned on : #{@host}"
      if @client then @client
      else @client = Client.connect(@host)
      end
    end
  end
  
  class Client
    def close
      @iprot.trans.close;
    end
    
    def Client.connect(host, port = 52980)
      dest = java.net.InetSocketAddress.new(host, port);
      puts "Connecting to #{dest.toString}";
      ret = Java::org::dbtoaster::cumulus::slicer::SlicerNode::getClient(dest);
      puts "Connected to #{dest.toString}";
      return ret
    end
  end
end

class SlicerMonitor
  def initialize(nodes, interval = 5)
    @nodes = nodes.collect do |node| 
      [ 
        conn = SlicerNode::Client.connect(node),
        out_blocker = Queue.new,
        in_blocker = Queue.new,
        Thread.new(node, conn, out_blocker, in_blocker) do |n, c, ob, ib|
          loop do
            ib.pop;
            ob.push(c.poll_stats.split("\n").collect { |l| "#{n}  #{l}"}.join("\n"))
          end
        end
      ]
    end
    @monitor = Thread.new(@nodes, interval) do |nodes, interval|
      loop do
        sleep interval;
        nodes.each { |c, ob, ib| ib.push(1) }
        log = nodes.collect { |c, ob, ib| ob.pop.split("\n") }.flatten.collect do |line|
          if /org.dbtoaster.cumulus.*Node/.match(line) then
            line.chomp.gsub(/java.*org.dbtoaster.cumulus.(.*Node).*/, "\\1")
          end
        end
        puts log.join("\n");
      end
    end
  end
end


#Logger.default_level = Logger::INFO;
#Logger.default_name = nil;

$verbosity = :normal;
$config_file = $config['config_file']
puts "Config file: #{$config_file}"

$local_node = PrimarySlicerNodeHandler.new($config_file, $verbosity);
return $local_node
