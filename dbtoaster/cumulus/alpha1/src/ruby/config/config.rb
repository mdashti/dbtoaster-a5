
require 'config/template';
require 'util/ok_mixins';
require 'getoptlong';

class RubyConfig
  attr_reader :templates, :nodes, :my_port,
    :switch, :num_switches, :switch_tree,
    :scholar,
    :log_maps, :client_debug,
    :spread_path, :compiler_path,
    :hadoop_path, :hadoop_dfs_path, :hadoop_job_path,
    :partition_sizes, :partition_owners;
  attr_writer :my_name, :my_port, :unknown_opts, :client_debug;
  
  def initialize
    @nodes = Hash.new { |h,k| h[k] = { 
      "partitions" => Hash.new  { |h,k| h[k] = Array.new },
      "values" => Hash.new { |h,k| h[k] = Hash.new }, 
      "address" => java::net::InetSocketAddress.new("localhost", 52982) 
    } };
    @templates = Hash.new;
    @partition_sizes = Hash.new { |h,k| h[k] = Array.new };
    @partition_owners = Hash.new { |h,k| h[k] = Hash.new };
    @my_name = nil;
    @my_port = 52982;
    @switch = java::net::InetSocketAddress.new("localhost", 52981);
    @log_maps = Array.new;
    
    @spread_path = "#{File.dirname(__FILE__)}/../.."
    if (@spread_path[0] != '/'[0]) || (@spread_path == "") then
      @spread_path = "#{`pwd`.chomp}/#{@spread_path}"
    end
    Logger.info { "Spread Path is : #{@spread_path}" }
    
    @compiler_path = nil;
    
    @hadoop_path = nil;
    @hadoop_dfs_path = nil;
    @hadoop_job_path = nil;

    @unknown_opts = Hash.new;
    @num_switches = 0;
    @switch_tree = [];

    # Debugging tools; Preprocessing that happens when the client reads from TPCH
    @client_debug = { 
      "transforms" => Array.new, 
      "projections" => Array.new, 
      "upfront" => Array.new,
      "sourcedir" => nil, 
      "ratelimit" => nil,
      "validate" => false
    }
  end
  
  def load(input)
    curr_node = "Solo Node"
    if(input.is_a? String) then
      input = File.new(input);
    end
    
    input.each do |line|
#      puts "Reading config line: " + line;
      cmd = line.scan(/[^ ]+/);
      case cmd[0].chomp
        when "node" then 
          curr_node = cmd[1].chomp;

        when "address" then
          address = cmd[1].chomp.split(/:/);
          port = (address[1] || 52982).to_i;
          address = address[0];
          @nodes[curr_node]["address"] = java::net::InetSocketAddress.new(address, port);
        
        when "switch"    then @switch = java::net::InetSocketAddress.new(cmd[1].chomp, 52981);

        when "switch_forwarders" then @num_switches = cmd[1].chomp.to_i;  

        when "switch_tree" then
          @switch_tree = cmd[1].chomp.split(",", 2).collect{ |p| p.to_i }

        when "scholar" then @scholar = java::net::InetSocketAddress.new(cmd[1].chomp, 52983); 

        when "partition" then 
          match = /Map *([0-9]+)\[([0-9, ]+)\]/.match(line);
          raise SpreadException.new("Unable to parse partition line: " + line) if match.nil?;
          dummy, map, segment = *match;
          segment = segment.split(/, */).collect { |i| i.to_i }
          
          @nodes[curr_node]["partitions"][map.to_i].push(segment);
          @partition_sizes[map.to_i] = 
            segment.zip(@partition_sizes[map.to_i]).collect { |sizes| if sizes[1].nil? then sizes[0].to_i+1 else Math.max(sizes[0]+1, sizes[1]) end };
          @partition_owners[map.to_i][segment] = @nodes[curr_node]["address"];
          
        when "value" then 
          match = /Map *([0-9]+) *\[([^\]]*)\] *v([0-9]+) *= *([0-9.]+)/.match(line)
          raise SpreadException.new("Unable to parse value line: " + line) if match.nil?;
          
          dummy, source, keys, version, value = *match;
          @nodes[curr_node]["values"][source.to_i][keys.split(/, */).collect do |k| k.to_i end] = value.to_f;

        when "spread_path" then cmd.shift; @spread_path = cmd.shift.chomp;
        
        when "template" then 
          cmd.shift; 
          index = cmd.shift.to_i
          @templates[index] = UpdateTemplate.new(cmd.join(" "), index);
        
        when "log_map"   then cmd.shift; @log_maps.add(cmd.shift.to_i);
        
        when "ratelimit" then cmd.shift; @client_debug["ratelimit"] = cmd.join(" ").chomp.to_i;
        when "transform" then cmd.shift; @client_debug["transforms"].push(cmd.join(" ").chomp);
        when "project"   then cmd.shift; @client_debug["projections"].push(cmd.join(" ").chomp);
        when "source"    then cmd.shift; @client_debug["sourcedir"] = cmd.join(" ").chomp;
        when "upfront"   then cmd.shift; @client_debug["upfront"].push(cmd.shift.chomp);
        when "validate"  then cmd.shift; @client_debug["validate"] = true; 
      end
    end
  end
  
  def load_local_properties(properties)
    if(properties.is_a? String) then
      properties = File.new(properties);
    end

    properties.each do |line|
      if line.strip != "" then
        opt, arg = line.split('=', 2)
        parse_opt(opt.strip,arg.strip)
      end
    end
    Java::org.apache.log4j.PropertyConfigurator.configure(properties.path);
  end

  def parse_opt(opt, arg)
    case opt
      when "-n", "--node" then 
        match = /([a-zA-Z0-9_\-]+)@([a-zA-Z0-9._\-]+)(:([0-9]+))?/.match(arg)
        raise "Invalid Node Parameter: " + arg unless match;
        @nodes[match[1]]["address"] = java::net::InetSocketAddress.new(match[2], match[4].to_i);
      when "cumulus.home" then
        @spread_path = arg.chomp;
      
      when "compiler.home" then
        @compiler_path = arg.chomp;
      
      when "hadoop.home" then
        @hadoop_path = arg.chomp;

      when "hadoop.dfs.home" then
        @hadoop_dfs_path = arg.chomp;

      when "hadoop.jobs.home" then
        @hadoop_job_path = arg.chomp;

      else
        @unknown_opts[opt] = arg;
    end
  end
  
  def [](opt)
    @unknown_opts[opt];
  end
  
  def each_partition(node)
    @nodes.fetch(node)["partitions"].each_pair do |map, plist|
      plist.each { |partition| yield map, partition }
    end
  end
  
  def each_value(node)
    @nodes.fetch(node)["values"].each_pair do |map, vlist|
      plist.each_pair { |key, value| yield map, key, value }
    end
  end
  
  def range_test(map)
    boundaries = @nodes.collect do |node, prefs|
      prefs["partitions"][map]
    end.concat!.matrix_transpose
    
    puts(boundaries.collect do |key_ranges|
      key_ranges.collect do |range|
        range.to_s;
      end.join(", ")
    end.join("\n"))
  end
  
  def partition_ranges(map)
    @nodes.collect do |node, prefs|
      prefs["partitions"][map]
    end.concat!.matrix_transpose.collect do |ranges|
      ranges.sort { |a, b| a.begin <=> b.begin }.uniq
    end
  end
  
  def node_for_entry(map, key)
    @nodes.each_pair do |node, prefs|
      if prefs["partitions"].has_key? map then
        prefs["partitions"][map].each do |range|
          return node if range.merge(key).assert { |pair| pair[0] === pair[1] }
        end
      end
    end
    return nil;
  end
  
  def address_for_node(node)
    raise SpreadException.new("Unknown Node: " + node) unless (@nodes.has_key? node)
    raise SpreadException.new("Unknown Node Address: " + node) unless (@nodes[node].has_key? "address")
    @nodes[node]["address"];
  end
  
  def map_keys(map)
    ret = nil;
    @templates.each_value do |t|
      if t.target.source == map then
        if ret then
          ret = ret.collect_pair(t.target.keys) do |old, new|
            if old.size <= new.size then old else new end;
          end
        else
          ret = t.target.keys.clone;
        end
      end 
    end
    ret;
  end
  
  def my_name
    return @my_name if @my_name;
    @nodes.each_pair do |node, info|
      return @my_name = node if (info["address"].port.to_i == @my_port.to_i) &&
                                ((info["address"].host_name == `hostname`.chomp) ||
                                 (info["address"].host_name == "localhost"));
    end
    "Solo Node";
  end
  
  def my_config
    @nodes[my_name];
  end
end

# Bit of a hack here, the RubyConfigIface is only required when running in pure java mode,
# but during the compilation process, we need to run some ruby code before the java code 
# has been compiled.  Consequently, we only include the Iface if we're running in java mode
if $jruby_config_mode != true then
  RubyConfig.class_eval('include Java::org::dbtoaster::cumulus::config::CumulusConfig::RubyConfigIface;');
end
$config = RubyConfig.new;