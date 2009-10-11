
require 'thrift'
require 'map_node'
require 'node'
require 'compiler'
require 'spread_types'
require 'spread_types_mixins'

class UnitTestNode
  attr_reader :handler, :name, :port;
  
  def initialize(port, name, config = Array.new)
    @name, @port, @thread = name, port, nil;
    @handler, @server = MapNode::Processor.listen(port, config)
    @client = nil;
  end
  
  def start
    @thread = Thread.new(@server, @name) do |server, name|
      Logger.info("Starting Node " + @name.to_s, "unit.rb @ " + name);
      begin
        server.serve;
      rescue Exception => e;
        puts "Error at Node " + name.to_s + ": " + e.to_s;
        puts e.backtrace.join("\n");
        exit;
      end
    end
  end
  
  def stop
    @thread.exit;
  end
  
  def dump
    "---" + @name.to_s + "---\n" + @handler.dump;
  end
  
  def to_s
    @name.to_s + "(@" + @port.to_s + ")";
  end
 
  def shutdown
    @client.close; @client = nil;
  end
  
  def client
    unless @client then
      Logger.info("Establishing connection to Node: " + @name + " @ port " + @port.to_s + " ...", "unit.rb");
      @client = MapNode::Client.connect("localhost", @port);
    end
    @client;
  end
end

###################################################

class UnitTestFetchStep
  def initialize(command, node_map)
    parsed = 
      / *([0-9]+) *:([^@]*)@ *([0-9a-zA-Z]+) *-> *([0-9a-zA-Z]+)/.match(command);
    raise SpreadException.new("Invalid fetch step string: " + command) if parsed == nil;
    
    @cmdid, @source, @dest = 
      parsed[1].to_i, node_map[parsed[3]], node_map[parsed[4]];
    
    @target = parsed[2].split(";").collect do |e| Entry.parse(e) end;
  end
  
  def fire
    @source.client.fetch(@target, NodeID.make("localhost", @dest.port), @cmdid);
  end
  
  def to_s
    @target.join(", ") + " @ " + @source.to_s + " -> " + @dest.to_s;
  end
end

class UnitTestPutStep
  def initialize(command, node_map, template_map)
    parsed = 
      / *([0-9]+) * : *Template *([0-9]+) *\(([0-9a-zA-Z, ]*)\) *@ *([0-9a-zA-Z]+)/.match(command)
    raise SpreadException.new("Invalid put step string: " + command) if parsed == nil || parsed.to_a.size != 5;
    parsed = parsed.to_a;
    parsed.shift; #first result is the overall match
    
    @cmdid, @template, @params, @dest = 
      parsed[0], parsed[1], Hash.new, node_map[parsed[3]];
    
    template_params = template_map[@template.to_i].paramlist.clone;
    parsed[2].split(/, */).each do |param|
      @params[template_params.shift] = param unless template_params.size <= 0;
    end
  end
  
  def fire
    @dest.client.put(@cmdid.to_i, @template.to_i, PutParams.make(@params));
  end
  
  def to_s
    @cmdid.to_s + " @ [localhost:" + @destport.to_s + "] : Template " + 
      @template.to_s + "(" + 
      @params.collect do |key, value| key.to_s + ":" + value.to_s end.join(", ") + ")";
  end
end

class UnitTestDumpStep
  def initialize(nodes)
    @nodes = nodes;
  end
  
  def fire
    @nodes.each do |unit_node| 
      Logger.info("---" + unit_node.name + "---", "unit.rb")
      unit_node.client.dump.each_line do |line|
        Logger.info(line.chomp, "unit.rb");
      end
    end
  end
  
  def to_s
    "Dump: " + @nodes.join(", ");
  end
end

class UnitTestSleepStep
  def initialize(time)
    @time = time.to_i;
  end 
  
  def fire
    sleep @time;
  end
  
  def to_s
    "Sleep: " + @time.to_s + " s";
  end
end

###################################################

class UnitTestHarness 
  def initialize()
    @nodes = Array.new;
    @testcmds = Array.new;
    @indexmap = Hash.new;
    @puttemplates = Hash.new;
  end
  
  def add_node(name = @nodes.size.to_s)
    node = UnitTestNode.new(52982 + @nodes.size, name);
    @indexmap[name] = node;
    Logger.info("New Node " + name.to_s + " : " + @nodes.size.to_s + " @ port " + node.port.to_s, "unit.rb");
    @nodes.push(node);
    node;
  end
  
  def start()
    @nodes.each do |node|
      node.start();
    end
  end
  
  def setup(input)
    cmdbuffer = Array.new;
    linebuffer = nil;
    nodename = nil;
    input.each do |line|
      Logger.debug("GOT: " + line.chomp, "unit.rb");
      if line[0] != '#' then 
        cmd = line.scan(/[^ \r\n]+/);
        case cmd[0]
          when "node" then 
            add_node(nodename).handler.setup(linebuffer) unless linebuffer == nil;
            if cmd.size > 1 then nodename = cmd[1] else nodename = @nodes.size.to_s; end
            linebuffer = Array.new;
          when "template" then
            cmd.shift; 
            @puttemplates[cmd.shift.to_i] = UpdateTemplate.new(cmd.join(" "));
          when "fetch", "put", "dump", "sleep" then cmdbuffer.push(cmd);
          else 
            linebuffer.push(line) unless linebuffer == nil;
        end
      end
    end
    add_node(nodename).handler.setup(linebuffer) unless linebuffer == nil;
    @nodes.each do |node|
      Logger.debug("Loading put templates into Node " + node.name, "unit.rb");
      @puttemplates.each_pair do |id, cmd|
        node.handler.install_put_template(id, cmd);
      end
    end
    cmdbuffer.each do |cmd|
      case cmd[0]
        when "fetch" then
          cmd.shift; 
          @testcmds.push(UnitTestFetchStep.new(cmd.join(" "), @indexmap));
        when "put" then
          cmd.shift;
          @testcmds.push(UnitTestPutStep.new(cmd.join(" "), @indexmap, @puttemplates));
        when "dump" then
          cmd.shift;
          if cmd.size > 0 then
            @testcmds.push(UnitTestDumpStep.new(cmd.collect do |node| @indexmap[node] end));
          else
            @testcmds.push(UnitTestDumpStep.new(@nodes));
          end
        when "sleep" then
          @testcmds.push(UnitTestSleepStep.new(cmd[1]));
      end
    end
  end
  
  def dump()
    @nodes.each do |node|
      node.dump.each_line do |line|
        Logger.info(line.chomp, "unit.rb");
      end
    end
  end
  
  def run()
    @testcmds.each do |cmd|
      Logger.info("Executing Test Step: " + cmd.to_s, "unit.rb");
      begin
        cmd.fire;
      rescue Exception => e;
        puts "Error while executing command (" + e.to_s + "); stopping run";
        puts e.backtrace.join("\n");
        break;
      end
    end
  end
  
end
